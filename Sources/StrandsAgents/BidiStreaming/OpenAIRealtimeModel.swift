import Foundation

/// OpenAI Realtime API bidi model via WebSocket.
///
/// Connects to `wss://api.openai.com/v1/realtime` for full-duplex
/// audio/text streaming with GPT-4o Realtime.
///
/// ```swift
/// let model = OpenAIRealtimeModel(apiKey: "sk-...", model: "gpt-4o-realtime-preview")
/// let agent = BidiAgent(model: model, config: BidiSessionConfig(voice: "alloy"))
/// ```
public final class OpenAIRealtimeModel: BidiModel, @unchecked Sendable {
    public var modelId: String? { model }
    public var config: [String: Any] {
        [
            "audio": [
                "input_rate": 24000,
                "output_rate": 24000,
                "channels": 1,
                "format": "pcm16",
            ] as [String: Any],
        ]
    }

    private let apiKey: String
    private let model: String
    private let baseURL: String
    private var webSocket: URLSessionWebSocketTask?
    private var eventContinuation: AsyncThrowingStream<BidiOutputEvent, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?

    public init(
        apiKey: String? = nil,
        model: String = "gpt-4o-realtime-preview",
        baseURL: String = "wss://api.openai.com/v1/realtime"
    ) {
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        self.model = model
        self.baseURL = baseURL
    }

    public func start(systemPrompt: String?, tools: [ToolSpec], messages: [Message]) async throws {
        let url = URL(string: "\(baseURL)?model=\(model)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let ws = URLSession.shared.webSocketTask(with: request)
        ws.resume()
        self.webSocket = ws

        // Configure session
        var sessionObj: [String: Any] = [
            "modalities": ["text", "audio"],
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "turn_detection": [
                "type": "server_vad",
                "silence_duration_ms": 500,
                "threshold": 0.5,
            ] as [String: Any],
        ]

        if let instructions = systemPrompt {
            sessionObj["instructions"] = instructions
        }

        if !tools.isEmpty {
            sessionObj["tools"] = tools.map { spec in
                [
                    "type": "function",
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": jsonValueToAny(JSONValue.object(spec.inputSchema)),
                ] as [String: Any]
            }
        }

        try await sendJSON(["type": "session.update", "session": sessionObj])
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
            try await sendJSON([
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString(),
            ])

        case .text(let text):
            try await sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": text]],
                ] as [String: Any],
            ])
            try await sendJSON(["type": "response.create"])

        case .interrupt:
            try await sendJSON(["type": "response.cancel"])

        case .end:
            try await sendJSON(["type": "input_audio_buffer.commit"])

        case .sessionUpdate, .image:
            break
        }
    }

    public func sendToolResult(_ result: ToolResultBlock) async throws {
        let content = result.content.compactMap { c -> String? in
            if case .text(let t) = c { return t }
            return nil
        }.joined()

        try await sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": result.toolUseId,
                "output": content,
            ] as [String: Any],
        ])
        try await sendJSON(["type": "response.create"])
    }

    public func receive() -> AsyncThrowingStream<BidiOutputEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<BidiOutputEvent, Error>.makeStream()
        self.eventContinuation = continuation

        receiveTask = Task { [weak self] in
            guard let self, let ws = self.webSocket else {
                continuation.finish()
                return
            }

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
        guard let type = json["type"] as? String else { return }

        switch type {
        case "session.created":
            continuation.yield(.connectionStarted(connectionId: UUID().uuidString))

        case "response.created":
            let id = (json["response"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
            continuation.yield(.responseStarted(responseId: id))

        case "response.audio.delta":
            if let audioB64 = json["delta"] as? String,
               let audioData = Data(base64Encoded: audioB64) {
                continuation.yield(.audio(audioData, format: .openAI))
            }

        case "response.audio_transcript.delta":
            if let text = json["delta"] as? String {
                continuation.yield(.textDelta(text))
            }

        case "response.audio_transcript.done":
            if let text = json["transcript"] as? String {
                continuation.yield(.transcript(role: .assistant, text: text, isFinal: true))
            }

        case "conversation.item.input_audio_transcription.completed":
            if let text = json["transcript"] as? String {
                continuation.yield(.inputSpeechDone(transcript: text))
                continuation.yield(.transcript(role: .user, text: text, isFinal: true))
            }

        case "input_audio_buffer.speech_started":
            continuation.yield(.inputSpeechStarted)
            continuation.yield(.interruption(reason: .userSpeech))

        case "response.done":
            let response = json["response"] as? [String: Any]
            let id = response?["id"] as? String ?? ""
            continuation.yield(.responseDone(responseId: id))

            // Extract usage
            if let usage = response?["usage"] as? [String: Any] {
                continuation.yield(.usage(Usage(
                    inputTokens: usage["input_tokens"] as? Int ?? 0,
                    outputTokens: usage["output_tokens"] as? Int ?? 0,
                    totalTokens: (usage["total_tokens"] as? Int)
                        ?? (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0)
                )))
            }

        case "response.function_call_arguments.done":
            if let name = json["name"] as? String,
               let argsStr = json["arguments"] as? String,
               let argsData = argsStr.data(using: .utf8),
               let argsJSON = try? JSONDecoder().decode(JSONValue.self, from: argsData) {
                continuation.yield(.toolCall(ToolUseBlock(
                    toolUseId: json["call_id"] as? String ?? UUID().uuidString,
                    name: name,
                    input: argsJSON
                )))
            }

        case "error":
            let errorMsg = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            continuation.yield(.error(errorMsg))

        default:
            break
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
