import Foundation
import AWSBedrockRuntime

/// AWS Nova Sonic bidi model via Bedrock's `InvokeModelWithBidirectionalStream` API.
///
/// Supports real-time voice conversations with tool calling.
/// 8-minute connection limit -- BidiAgent auto-reconnects.
///
/// ```swift
/// let model = try NovaSonicModel(region: "us-east-1")
/// let agent = BidiAgent(model: model, config: BidiSessionConfig(voice: "tiffany"))
/// try await agent.start()
/// ```
public final class NovaSonicModel: BidiModel, @unchecked Sendable {
    public var modelId: String? { model }
    public var config: [String: Any] {
        ["audio": [
            "input_rate": 16000, "output_rate": 16000,
            "channels": 1, "format": "pcm16", "voice": voice,
        ] as [String: Any]]
    }

    private let model: String
    private let region: String
    private let voice: String
    private let connectionTimeout: TimeInterval
    private let client: BedrockRuntimeClient

    private var inputContinuation: AsyncThrowingStream<BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput, Error>.Continuation?
    private var outputBody: AsyncThrowingStream<BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamOutput, Error>?
    private var connectionId: String = ""
    private var audioContentName: String? = nil
    private let sendLock = NSLock()

    public init(
        model: String = "amazon.nova-sonic-v1:0",
        region: String = "us-east-1",
        voice: String = "tiffany",
        connectionTimeout: TimeInterval = 480
    ) throws {
        self.model = model
        self.region = region
        self.voice = voice
        self.connectionTimeout = connectionTimeout
        var clientConfig = try BedrockRuntimeClient.BedrockRuntimeClientConfiguration(region: region)
        clientConfig.httpClientConfiguration.socketTimeout = connectionTimeout
        self.client = BedrockRuntimeClient(config: clientConfig)
    }

    // MARK: - BidiModel

    public func start(systemPrompt: String?, tools: [ToolSpec], messages: [Message]) async throws {
        connectionId = UUID().uuidString
        audioContentName = nil

        let (inputStream, continuation) = AsyncThrowingStream<BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput, Error>.makeStream()
        self.inputContinuation = continuation

        let output = try await client.invokeModelWithBidirectionalStream(
            input: InvokeModelWithBidirectionalStreamInput(body: inputStream, modelId: model)
        )
        self.outputBody = output.body

        // Session start
        try await sendJSON([
            "event": ["sessionStart": [
                "inferenceConfiguration": [
                    "maxTokens": 1024, "topP": 0.9, "temperature": 0.7,
                ],
            ]],
        ])

        // Prompt start
        var promptStart: [String: Any] = [
            "promptName": connectionId,
            "textOutputConfiguration": ["mediaType": "text/plain"],
            "audioOutputConfiguration": [
                "mediaType": "audio/lpcm",
                "sampleRateHertz": 16000, "sampleSizeBits": 16,
                "channelCount": 1, "voiceId": voice,
                "encoding": "base64", "audioType": "SPEECH",
            ] as [String: Any],
        ]

        if let sys = systemPrompt {
            // System prompt as a text content block before the prompt
            promptStart["systemPrompt"] = sys
        }

        if !tools.isEmpty {
            promptStart["toolConfiguration"] = ["tools": tools.map { spec in
                [
                    "toolSpec": [
                        "name": spec.name,
                        "description": spec.description,
                        "inputSchema": ["json": jsonToString(JSONValue.object(spec.inputSchema))],
                    ],
                ] as [String: Any]
            }]
            promptStart["toolUseOutputConfiguration"] = ["mediaType": "text/plain"]
        }

        try await sendJSON(["event": ["promptStart": promptStart]])

        // Restore conversation history as text content blocks
        for message in messages {
            let text = message.textContent
            guard !text.isEmpty else { continue }
            let role = message.role == .user ? "USER" : "ASSISTANT"
            let contentName = UUID().uuidString

            try await sendJSON(["event": ["contentStart": [
                "promptName": connectionId,
                "contentName": contentName,
                "type": "TEXT",
                "role": role,
            ]]])
            try await sendJSON(["event": ["textInput": [
                "promptName": connectionId,
                "contentName": contentName,
                "content": text,
            ]]])
            try await sendJSON(["event": ["contentEnd": [
                "promptName": connectionId,
                "contentName": contentName,
            ]]])
        }

        // Start audio input connection
        await startAudioConnection()
    }

    public func stop() async {
        await endAudioInput()
        try? await sendJSON(["event": ["contentEnd": [
            "promptName": connectionId,
            "contentName": connectionId,
        ]]])
        inputContinuation?.finish()
        inputContinuation = nil
        outputBody = nil
    }

    public func send(_ event: BidiInputEvent) async throws {
        switch event {
        case .audio(let data, _):
            if audioContentName == nil {
                await startAudioConnection()
            }
            guard let name = audioContentName else { return }
            try await sendJSON(["event": ["audioInput": [
                "promptName": connectionId,
                "contentName": name,
                "content": data.base64EncodedString(),
            ]]])

        case .text(let text):
            await endAudioInput()
            let contentName = UUID().uuidString
            try await sendJSON(["event": ["contentStart": [
                "promptName": connectionId,
                "contentName": contentName,
                "type": "TEXT",
                "role": "USER",
            ]]])
            try await sendJSON(["event": ["textInput": [
                "promptName": connectionId,
                "contentName": contentName,
                "content": text,
            ]]])
            try await sendJSON(["event": ["contentEnd": [
                "promptName": connectionId,
                "contentName": contentName,
            ]]])

        case .interrupt:
            break

        case .end:
            await endAudioInput()
            try await sendJSON(["event": ["promptEnd": [
                "promptName": connectionId,
            ]]])

        case .sessionUpdate, .image:
            break
        }
    }

    public func sendToolResult(_ result: ToolResultBlock) async throws {
        let content = result.content.compactMap { c -> String? in
            if case .text(let t) = c { return t }
            return nil
        }.joined()
        let contentName = UUID().uuidString

        try await sendJSON(["event": ["contentStart": [
            "promptName": connectionId,
            "contentName": contentName,
            "type": "TOOL_RESULT",
            "role": "TOOL",
            "toolResultInputConfiguration": ["toolUseId": result.toolUseId, "type": "TEXT"],
        ]]])
        try await sendJSON(["event": ["textInput": [
            "promptName": connectionId,
            "contentName": contentName,
            "content": content,
        ]]])
        try await sendJSON(["event": ["contentEnd": [
            "promptName": connectionId,
            "contentName": contentName,
        ]]])
    }

    public func receive() -> AsyncThrowingStream<BidiOutputEvent, Error> {
        guard let body = outputBody else {
            return AsyncThrowingStream { $0.finish() }
        }

        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }

                continuation.yield(.connectionStarted(connectionId: self.connectionId))

                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(self.connectionTimeout))
                    continuation.finish(throwing: BidiModelTimeoutError())
                }

                do {
                    for try await event in body {
                        guard case .chunk(let part) = event,
                              let bytes = part.bytes, !bytes.isEmpty
                        else { continue }

                        self.parseOutputEvent(bytes, continuation: continuation)
                    }
                    timeoutTask.cancel()
                    continuation.yield(.sessionEnded(reason: .complete))
                    continuation.finish()
                } catch {
                    timeoutTask.cancel()
                    if error is BidiModelTimeoutError {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.yield(.error(error.localizedDescription))
                        continuation.yield(.sessionEnded(reason: .error))
                        continuation.finish()
                    }
                }
            }
        }
    }

    // MARK: - Audio Connection

    private func startAudioConnection() async {
        let name = UUID().uuidString
        audioContentName = name

        try? await sendJSON(["event": ["contentStart": [
            "promptName": connectionId,
            "contentName": name,
            "type": "AUDIO",
            "interactive": true,
            "role": "USER",
            "audioInputConfiguration": [
                "mediaType": "audio/lpcm",
                "sampleRateHertz": 16000, "sampleSizeBits": 16,
                "channelCount": 1, "audioType": "SPEECH", "encoding": "base64",
            ] as [String: Any],
        ]]])
    }

    private func endAudioInput() async {
        guard let name = audioContentName else { return }
        try? await sendJSON(["event": ["contentEnd": [
            "promptName": connectionId, "contentName": name,
        ]]])
        audioContentName = nil
    }

    // MARK: - Output Parsing

    private func parseOutputEvent(
        _ data: Data,
        continuation: AsyncThrowingStream<BidiOutputEvent, Error>.Continuation
    ) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? [String: Any]
        else { return }

        // Audio output
        if let audioOutput = event["audioOutput"] as? [String: Any],
           let audioB64 = audioOutput["content"] as? String,
           let audioData = Data(base64Encoded: audioB64) {
            continuation.yield(.audio(audioData, format: .novaSonic))
        }

        // Text output
        if let textOutput = event["textOutput"] as? [String: Any],
           let content = textOutput["content"] as? String {
            let role: Role = (textOutput["role"] as? String) == "USER" ? .user : .assistant
            continuation.yield(.transcript(role: role, text: content, isFinal: true))
            if role == .assistant {
                continuation.yield(.textDelta(content))
            }
        }

        // Tool use
        if let toolUse = event["toolUse"] as? [String: Any],
           let toolName = toolUse["toolName"] as? String,
           let toolUseId = toolUse["toolUseId"] as? String {
            let inputStr = toolUse["content"] as? String ?? "{}"
            let input: JSONValue
            if let d = inputStr.data(using: .utf8), let decoded = try? JSONDecoder().decode(JSONValue.self, from: d) {
                input = decoded
            } else {
                input = .object([:])
            }
            continuation.yield(.toolCall(ToolUseBlock(toolUseId: toolUseId, name: toolName, input: input)))
        }

        // Content start (audio response starting)
        if let contentStart = event["contentStart"] as? [String: Any],
           let type = contentStart["type"] as? String, type == "AUDIO" {
            continuation.yield(.responseStarted(responseId: UUID().uuidString))
        }

        // Content end
        if let contentEnd = event["contentEnd"] as? [String: Any] {
            let stopReason = contentEnd["stopReason"] as? String
            if stopReason == "INTERRUPTED" {
                continuation.yield(.interruption(reason: .userSpeech))
            }
            continuation.yield(.responseDone(responseId: UUID().uuidString))
        }

        // Usage
        if let usage = event["usage"] as? [String: Any] {
            continuation.yield(.usage(Usage(
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                totalTokens: (usage["inputTokens"] as? Int ?? 0) + (usage["outputTokens"] as? Int ?? 0)
            )))
        }
    }

    // MARK: - Helpers

    private func sendJSON(_ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        inputContinuation?.yield(.chunk(
            BedrockRuntimeClientTypes.BidirectionalInputPayloadPart(bytes: data)
        ))
    }

    private func jsonToString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }
}
