import Foundation
import StrandsAgents

/// Google Gemini Live API bidi model via WebSocket.
///
/// Connects to Gemini's Live API for real-time multimodal conversations
/// supporting audio, text, and image input.
///
/// ```swift
/// let model = GeminiLiveModel(apiKey: "...", model: "gemini-2.0-flash-live")
/// let agent = BidiAgent(model: model, config: BidiSessionConfig(voice: "Puck"))
/// ```
public final class GeminiLiveModel: BidiModel, @unchecked Sendable {
    public var modelId: String? { model }
    public var config: [String: Any] {
        [
            "audio": [
                "input_rate": 16000,
                "output_rate": 24000,
                "channels": 1,
                "format": "pcm16",
            ] as [String: Any],
        ]
    }

    private let apiKey: String
    private let model: String
    private var webSocket: URLSessionWebSocketTask?
    private var eventContinuation: AsyncThrowingStream<BidiOutputEvent, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?

    public init(
        apiKey: String? = nil,
        model: String = "gemini-2.0-flash-live"
    ) {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"] ?? ""
        self.model = model
    }

    public func start(systemPrompt: String?, tools: [ToolSpec], messages: [Message]) async throws {
        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw StrandsError.providerError(
                underlying: NSError(domain: "GeminiLive", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            )
        }

        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()
        self.webSocket = ws

        // Send setup message
        var setup: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generation_config": [
                    "response_modalities": ["AUDIO", "TEXT"],
                    "speech_config": [
                        "voice_config": [
                            "prebuilt_voice_config": [
                                "voice_name": "Puck",
                            ],
                        ],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]

        if let prompt = systemPrompt {
            var setupDict = setup["setup"] as! [String: Any]
            setupDict["system_instruction"] = [
                "parts": [["text": prompt]],
            ]
            setup["setup"] = setupDict
        }

        if !tools.isEmpty {
            var setupDict = setup["setup"] as! [String: Any]
            setupDict["tools"] = [
                [
                    "function_declarations": tools.map { spec in
                        [
                            "name": spec.name,
                            "description": spec.description,
                            "parameters": jsonValueToAny(JSONValue.object(spec.inputSchema)),
                        ] as [String: Any]
                    },
                ],
            ]
            setup["setup"] = setupDict
        }

        try await sendJSON(setup)
    }

    public func stop() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }

    public func send(_ event: BidiInputEvent) async throws {
        switch event {
        case .audio(let data, _):
            // Gemini uses realtime_input for audio with VAD
            try await sendJSON([
                "realtime_input": [
                    "media_chunks": [
                        [
                            "data": data.base64EncodedString(),
                            "mime_type": "audio/pcm;rate=16000",
                        ],
                    ],
                ],
            ])

        case .text(let text):
            try await sendJSON([
                "client_content": [
                    "turns": [
                        ["role": "user", "parts": [["text": text]]],
                    ],
                    "turn_complete": true,
                ],
            ])

        case .image(let data, let mimeType):
            try await sendJSON([
                "realtime_input": [
                    "media_chunks": [
                        [
                            "data": data.base64EncodedString(),
                            "mime_type": mimeType,
                        ],
                    ],
                ],
            ])

        case .interrupt, .end, .sessionUpdate:
            break
        }
    }

    public func sendToolResult(_ result: ToolResultBlock) async throws {
        let content = result.content.compactMap { c -> String? in
            if case .text(let t) = c { return t }
            return nil
        }.joined()

        try await sendJSON([
            "tool_response": [
                "function_responses": [
                    [
                        "id": result.toolUseId,
                        "name": "function_response",
                        "response": ["result": content],
                    ],
                ],
            ],
        ])
    }

    public func receive() -> AsyncThrowingStream<BidiOutputEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<BidiOutputEvent, Error>.makeStream()
        self.eventContinuation = continuation

        receiveTask = Task { [weak self] in
            guard let self, let ws = self.webSocket else {
                continuation.finish()
                return
            }

            continuation.yield(.connectionStarted(connectionId: UUID().uuidString))

            while ws.state == .running {
                do {
                    let message = try await ws.receive()
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            self.handleServerEvent(json, continuation: continuation)
                        }
                    case .data(let data):
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            self.handleServerEvent(json, continuation: continuation)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                    return
                }
            }
            continuation.finish()
        }

        return stream
    }

    // MARK: - Private

    private func handleServerEvent(
        _ json: [String: Any],
        continuation: AsyncThrowingStream<BidiOutputEvent, Error>.Continuation
    ) {
        // Setup complete
        if json["setupComplete"] != nil {
            return
        }

        // Server content (audio/text response)
        if let serverContent = json["serverContent"] as? [String: Any] {
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String {
                        continuation.yield(.textDelta(text))
                    }
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let b64 = inlineData["data"] as? String,
                       let audioData = Data(base64Encoded: b64) {
                        continuation.yield(.audio(audioData, format: .geminiLive))
                    }
                }
            }

            if serverContent["turnComplete"] as? Bool == true {
                continuation.yield(.responseDone(responseId: UUID().uuidString))
            }

            // Input transcription
            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTranscription["text"] as? String {
                continuation.yield(.transcript(role: .user, text: text, isFinal: true))
            }

            // Output transcription
            if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
               let text = outputTranscription["text"] as? String {
                continuation.yield(.transcript(role: .assistant, text: text, isFinal: true))
            }
        }

        // Tool call
        if let toolCall = json["toolCall"] as? [String: Any],
           let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
            for fc in functionCalls {
                let name = fc["name"] as? String ?? ""
                let id = fc["id"] as? String ?? UUID().uuidString
                let args: JSONValue
                if let argsDict = fc["args"] as? [String: Any],
                   let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                   let decoded = try? JSONDecoder().decode(JSONValue.self, from: argsData) {
                    args = decoded
                } else {
                    args = .object([:])
                }
                continuation.yield(.toolCall(ToolUseBlock(toolUseId: id, name: name, input: args)))
            }
        }

        // Usage
        if let usageMetadata = json["usageMetadata"] as? [String: Any] {
            continuation.yield(.usage(Usage(
                inputTokens: usageMetadata["promptTokenCount"] as? Int ?? 0,
                outputTokens: usageMetadata["candidatesTokenCount"] as? Int ?? 0,
                totalTokens: usageMetadata["totalTokenCount"] as? Int ?? 0
            )))
        }
    }

    private func sendJSON(_ obj: [String: Any]) async throws {
        guard let ws = webSocket else { return }
        let data = try JSONSerialization.data(withJSONObject: obj)
        let string = String(data: data, encoding: .utf8)!
        try await ws.send(.string(string))
    }

    private func jsonValueToAny(_ value: JSONValue) -> Any {
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
