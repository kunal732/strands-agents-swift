import Foundation

/// OpenAI Chat Completions API provider with streaming and tool calling.
///
/// ```swift
/// let provider = OpenAIProvider(config: OpenAIConfig(modelId: "gpt-4o"))
/// let agent = Agent(model: provider, tools: [MyTool()])
/// ```
///
/// Also works with Azure OpenAI and any OpenAI-compatible API by changing `baseURL`.
public final class OpenAIProvider: ModelProvider, @unchecked Sendable {
    public var modelId: String? { config.modelId }

    private var config: OpenAIConfig
    private let session: URLSession

    public init(config: OpenAIConfig = OpenAIConfig()) {
        self.config = config
        self.session = URLSession(configuration: .default)
    }

    public convenience init(modelId: String) {
        self.init(config: OpenAIConfig(modelId: modelId))
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

                    var request = URLRequest(url: URL(string: "\(config.baseURL)/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.httpBody = jsonData

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: StrandsError.providerError(
                            underlying: OpenAIProviderError.invalidResponse(statusCode: 0, body: "Not HTTP")
                        ))
                        return
                    }

                    if httpResponse.statusCode == 429 {
                        let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                            .flatMap(TimeInterval.init)
                        continuation.finish(throwing: StrandsError.modelThrottled(retryAfter: retryAfter))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        continuation.finish(throwing: StrandsError.providerError(
                            underlying: OpenAIProviderError.invalidResponse(
                                statusCode: httpResponse.statusCode, body: errorBody
                            )
                        ))
                        return
                    }

                    // Parse SSE stream
                    continuation.yield(.messageStart(role: .assistant))
                    var hasStartedText = false
                    var toolCalls: [String: (name: String, args: String)] = [:]
                    var pendingStopReason: StopReason = .endTurn

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let dataStr = String(line.dropFirst(6))
                        if dataStr == "[DONE]" { break }

                        guard let jsonData = dataStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let choice = choices.first
                        else { continue }

                        // Check finish_reason
                        if let finishReason = choice["finish_reason"] as? String {
                            switch finishReason {
                            case "tool_calls": pendingStopReason = .toolUse
                            case "length": pendingStopReason = .maxTokens
                            case "content_filter": pendingStopReason = .contentFiltered
                            default: pendingStopReason = .endTurn
                            }
                        }

                        guard let delta = choice["delta"] as? [String: Any] else { continue }

                        // Text content
                        if let content = delta["content"] as? String, !content.isEmpty {
                            if !hasStartedText {
                                continuation.yield(.contentBlockStart(ContentBlockStartData()))
                                hasStartedText = true
                            }
                            continuation.yield(.contentBlockDelta(.text(content)))
                        }

                        // Tool calls
                        if let tcs = delta["tool_calls"] as? [[String: Any]] {
                            for tc in tcs {
                                let index = tc["index"] as? Int ?? 0
                                let key = "\(index)"

                                if let function = tc["function"] as? [String: Any] {
                                    if let name = function["name"] as? String {
                                        // New tool call starting
                                        if hasStartedText {
                                            continuation.yield(.contentBlockStop)
                                            hasStartedText = false
                                        }

                                        let id = tc["id"] as? String ?? UUID().uuidString
                                        toolCalls[key] = (name: name, args: "")

                                        continuation.yield(.contentBlockStart(ContentBlockStartData(
                                            toolUse: ToolUseStart(toolUseId: id, name: name)
                                        )))
                                    }

                                    if let args = function["arguments"] as? String {
                                        toolCalls[key]?.args += args
                                        continuation.yield(.contentBlockDelta(.toolUseInput(args)))
                                    }
                                }
                            }
                        }
                    }

                    // Close any open blocks
                    if hasStartedText {
                        continuation.yield(.contentBlockStop)
                    }
                    // Close tool call blocks
                    if !toolCalls.isEmpty && !hasStartedText {
                        continuation.yield(.contentBlockStop)
                    }

                    continuation.yield(.messageStop(stopReason: pendingStopReason))
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
        config: OpenAIConfig,
        systemPrompt: String?,
        toolSpecs: [ToolSpec]?,
        toolChoice: ToolChoice?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.modelId,
            "max_tokens": config.maxTokens,
            "stream": true,
        ]

        if let temp = config.temperature { body["temperature"] = temp }
        if let tp = config.topP { body["top_p"] = tp }

        // Build messages array
        var apiMessages: [[String: Any]] = []

        if let system = systemPrompt {
            apiMessages.append(["role": "system", "content": system])
        }

        for message in messages {
            apiMessages.append(convertMessage(message))
        }

        body["messages"] = apiMessages

        // Tools
        if let specs = toolSpecs, !specs.isEmpty {
            body["tools"] = specs.map { spec in
                [
                    "type": "function",
                    "function": [
                        "name": spec.name,
                        "description": spec.description,
                        "parameters": jsonValueToAny(JSONValue.object(spec.inputSchema)),
                    ] as [String: Any],
                ] as [String: Any]
            }

            if let choice = toolChoice {
                switch choice {
                case .auto: body["tool_choice"] = "auto"
                case .any: body["tool_choice"] = "required"
                case .tool(let name):
                    body["tool_choice"] = ["type": "function", "function": ["name": name]]
                case .none: body["tool_choice"] = "none"
                }
            }
        }

        return body
    }

    private static func convertMessage(_ message: Message) -> [String: Any] {
        let role = message.role == .user ? "user" : "assistant"

        // Check for tool results (user messages with tool_result blocks)
        let toolResults = message.toolResults
        if !toolResults.isEmpty {
            // In OpenAI format, each tool result is a separate "tool" role message
            // But we can only return one message here, so we return the first one.
            // The caller should handle splitting if needed.
            let first = toolResults[0]
            let content = first.content.map { c -> String in
                switch c {
                case .text(let t): return t
                case .json(let v): return "\(jsonValueToAny(v))"
                default: return ""
                }
            }.joined()

            return [
                "role": "tool",
                "tool_call_id": first.toolUseId,
                "content": content,
            ]
        }

        // Check for tool use blocks in assistant messages
        let toolUses = message.toolUses
        if !toolUses.isEmpty {
            var msg: [String: Any] = ["role": "assistant"]
            let text = message.textContent
            if !text.isEmpty { msg["content"] = text }

            msg["tool_calls"] = toolUses.map { tu in
                [
                    "id": tu.toolUseId,
                    "type": "function",
                    "function": [
                        "name": tu.name,
                        "arguments": {
                            if let data = try? JSONSerialization.data(
                                withJSONObject: jsonValueToAny(tu.input)
                            ), let str = String(data: data, encoding: .utf8) {
                                return str
                            }
                            return "{}"
                        }(),
                    ] as [String: Any],
                ] as [String: Any]
            }
            return msg
        }

        // Plain text message
        return ["role": role, "content": message.textContent]
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
