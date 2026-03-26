import Foundation

/// Google Gemini API provider using the `generateContent` streaming endpoint.
///
/// ```swift
/// let provider = GeminiProvider(config: GeminiConfig(modelId: "gemini-2.5-flash"))
/// let agent = Agent(model: provider, tools: [MyTool()])
/// ```
///
/// Supports text, tool calling, images, and documents via the Gemini REST API.
/// If no API key is provided, reads from the `GOOGLE_API_KEY` environment variable.
public final class GeminiProvider: ModelProvider, @unchecked Sendable {
    public var modelId: String? { config.modelId }
    public var genAISystem: String { "google_ai_studio" }

    private var config: GeminiConfig
    private let session: URLSession

    public init(config: GeminiConfig = GeminiConfig()) {
        self.config = config
        self.session = URLSession(configuration: .default)
    }

    public convenience init(modelId: String) {
        self.init(config: GeminiConfig(modelId: modelId))
    }

    // MARK: - ModelProvider

    public func stream(
        messages: [Message],
        toolSpecs: [ToolSpec]?,
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let config = self.config
        let session = self.session

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let apiKey = try config.resolvedApiKey()
                    let body = Self.buildRequestBody(
                        messages: messages, config: config,
                        systemPrompt: systemPrompt, toolSpecs: toolSpecs, toolChoice: toolChoice
                    )

                    let jsonData = try JSONSerialization.data(withJSONObject: body)
                    let url = URL(string: "\(config.baseURL)/models/\(config.modelId):streamGenerateContent?alt=sse&key=\(apiKey)")!

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = jsonData

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: StrandsError.providerError(
                            underlying: GeminiProviderError.invalidResponse(statusCode: 0, body: "Not HTTP")
                        ))
                        return
                    }

                    if httpResponse.statusCode == 429 {
                        continuation.finish(throwing: StrandsError.modelThrottled(retryAfter: nil))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        continuation.finish(throwing: StrandsError.providerError(
                            underlying: GeminiProviderError.invalidResponse(
                                statusCode: httpResponse.statusCode, body: errorBody
                            )
                        ))
                        return
                    }

                    // Parse SSE stream
                    continuation.yield(.messageStart(role: .assistant))
                    var hasOpenBlock = false
                    var hasToolCalls = false

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let dataStr = String(line.dropFirst(6))
                        if dataStr == "[DONE]" { break }

                        guard let jsonData = dataStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let candidate = candidates.first,
                              let content = candidate["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]]
                        else { continue }

                        for part in parts {
                            // Text content
                            if let text = part["text"] as? String {
                                if !hasOpenBlock {
                                    continuation.yield(.contentBlockStart(ContentBlockStartData()))
                                    hasOpenBlock = true
                                }
                                continuation.yield(.contentBlockDelta(.text(text)))
                            }

                            // Function call (tool use)
                            if let functionCall = part["functionCall"] as? [String: Any],
                               let name = functionCall["name"] as? String {
                                // Close any open text block
                                if hasOpenBlock {
                                    continuation.yield(.contentBlockStop)
                                    hasOpenBlock = false
                                }

                                hasToolCalls = true
                                let toolUseId = UUID().uuidString

                                continuation.yield(.contentBlockStart(ContentBlockStartData(
                                    toolUse: ToolUseStart(toolUseId: toolUseId, name: name)
                                )))

                                // Serialize args
                                if let args = functionCall["args"] as? [String: Any],
                                   let argsData = try? JSONSerialization.data(withJSONObject: args),
                                   let argsStr = String(data: argsData, encoding: .utf8) {
                                    continuation.yield(.contentBlockDelta(.toolUseInput(argsStr)))
                                }
                                continuation.yield(.contentBlockStop)
                            }
                        }

                        // Check finish reason
                        if let finishReason = candidate["finishReason"] as? String {
                            if hasOpenBlock {
                                continuation.yield(.contentBlockStop)
                                hasOpenBlock = false
                            }

                            let stopReason: StopReason
                            switch finishReason {
                            case "STOP": stopReason = .endTurn
                            case "MAX_TOKENS": stopReason = .maxTokens
                            case "SAFETY": stopReason = .contentFiltered
                            default: stopReason = hasToolCalls ? .toolUse : .endTurn
                            }

                            // Usage
                            if let usageMetadata = json["usageMetadata"] as? [String: Any] {
                                continuation.yield(.metadata(
                                    usage: Usage(
                                        inputTokens: usageMetadata["promptTokenCount"] as? Int ?? 0,
                                        outputTokens: usageMetadata["candidatesTokenCount"] as? Int ?? 0,
                                        totalTokens: usageMetadata["totalTokenCount"] as? Int ?? 0,
                                        cacheReadInputTokens: usageMetadata["cachedContentTokenCount"] as? Int
                                    ),
                                    metrics: nil
                                ))
                            }

                            continuation.yield(.messageStop(stopReason: stopReason))
                        }
                    }

                    // Close any remaining open block
                    if hasOpenBlock {
                        continuation.yield(.contentBlockStop)
                    }

                    continuation.finish()
                } catch {
                    if let se = error as? StrandsError {
                        continuation.finish(throwing: se)
                    } else {
                        continuation.finish(throwing: StrandsError.providerError(underlying: error))
                    }
                }
            }
        }
    }

    // MARK: - Request Building

    private static func buildRequestBody(
        messages: [Message],
        config: GeminiConfig,
        systemPrompt: String?,
        toolSpecs: [ToolSpec]?,
        toolChoice: ToolChoice?
    ) -> [String: Any] {
        var body: [String: Any] = [:]

        // System instruction
        if let system = systemPrompt {
            body["systemInstruction"] = [
                "parts": [["text": system]],
            ]
        }

        // Generation config
        var genConfig: [String: Any] = [
            "maxOutputTokens": config.maxTokens,
        ]
        if let temp = config.temperature { genConfig["temperature"] = temp }
        if let tp = config.topP { genConfig["topP"] = tp }
        body["generationConfig"] = genConfig

        // Contents (messages)
        body["contents"] = messages.map { convertMessage($0) }

        // Tools
        if let specs = toolSpecs, !specs.isEmpty {
            body["tools"] = [
                [
                    "functionDeclarations": specs.map { spec in
                        [
                            "name": spec.name,
                            "description": spec.description,
                            "parameters": jsonValueToAny(JSONValue.object(spec.inputSchema)),
                        ] as [String: Any]
                    },
                ],
            ]

            if let choice = toolChoice {
                switch choice {
                case .auto:
                    body["toolConfig"] = ["functionCallingConfig": ["mode": "AUTO"]]
                case .any:
                    body["toolConfig"] = ["functionCallingConfig": ["mode": "ANY"]]
                case .tool(let name):
                    body["toolConfig"] = ["functionCallingConfig": [
                        "mode": "ANY",
                        "allowedFunctionNames": [name],
                    ]]
                case .none:
                    body["toolConfig"] = ["functionCallingConfig": ["mode": "NONE"]]
                }
            }
        }

        return body
    }

    private static func convertMessage(_ message: Message) -> [String: Any] {
        let role = message.role == .user ? "user" : "model"
        var parts: [[String: Any]] = []

        for block in message.content {
            switch block {
            case .text(let tb):
                parts.append(["text": tb.text])

            case .toolUse(let tu):
                var args: Any = [String: Any]()
                if let data = try? JSONEncoder().encode(tu.input),
                   let dict = try? JSONSerialization.jsonObject(with: data) {
                    args = dict
                }
                parts.append([
                    "functionCall": [
                        "name": tu.name,
                        "args": args,
                    ],
                ])

            case .toolResult(let tr):
                let content = tr.content.compactMap { c -> String? in
                    if case .text(let t) = c { return t }
                    return nil
                }.joined()
                parts.append([
                    "functionResponse": [
                        "name": "function_response",
                        "response": ["result": content],
                    ],
                ])

            case .image(let img):
                if case .base64(let mediaType, let data) = img.source {
                    parts.append([
                        "inlineData": [
                            "mimeType": mediaType,
                            "data": data,
                        ],
                    ])
                }

            default:
                break
            }
        }

        return ["role": role, "parts": parts]
    }

    private static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
        }
    }
}
