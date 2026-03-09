import Foundation
import StrandsAgents
import AWSBedrockRuntime

/// AWS Nova Sonic bidi model via Bedrock's `InvokeModelWithBidirectionalStream` API.
///
/// Nova Sonic supports real-time voice conversations with tool calling.
/// Has an 8-minute connection limit -- the BidiAgent automatically reconnects.
///
/// ```swift
/// let model = try NovaSonicModel(region: "us-east-1")
/// let agent = BidiAgent(model: model, config: BidiSessionConfig(voice: "tiffany"))
/// try await agent.start()
/// ```
public final class NovaSonicModel: BidiModel, @unchecked Sendable {
    public var modelId: String? { model }
    public var config: [String: Any] {
        [
            "audio": [
                "input_rate": 16000,
                "output_rate": 16000,
                "channels": 1,
                "format": "pcm16",
                "voice": voice,
            ] as [String: Any],
        ]
    }

    private let model: String
    private let region: String
    private let voice: String
    private let connectionTimeout: TimeInterval
    private let client: BedrockRuntimeClient

    private var inputContinuation: AsyncThrowingStream<BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput, Error>.Continuation?
    private var outputBody: AsyncThrowingStream<BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamOutput, Error>?
    private var sessionId: String = ""
    private var promptId: String = ""
    private var contentId: String = ""

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

        let clientConfig = try BedrockRuntimeClient.BedrockRuntimeClientConfiguration(region: region)
        self.client = BedrockRuntimeClient(config: clientConfig)
    }

    public func start(systemPrompt: String?, tools: [ToolSpec], messages: [Message]) async throws {
        sessionId = UUID().uuidString
        promptId = UUID().uuidString
        contentId = UUID().uuidString

        // Create the bidirectional input stream
        let (inputStream, continuation) = AsyncThrowingStream<BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput, Error>.makeStream()
        self.inputContinuation = continuation

        // Call Bedrock's bidirectional stream API
        let output = try await client.invokeModelWithBidirectionalStream(
            input: InvokeModelWithBidirectionalStreamInput(
                body: inputStream,
                modelId: model
            )
        )
        self.outputBody = output.body

        // Send session start
        try await sendEvent(NovaSonicEvent.sessionStart(sessionId: sessionId))

        // Send prompt start with config
        try await sendEvent(NovaSonicEvent.promptStart(
            promptId: promptId,
            systemPrompt: systemPrompt,
            tools: tools,
            voice: voice
        ))

        // Restore conversation history
        for message in messages {
            let text = message.textContent
            if !text.isEmpty {
                let role = message.role == .user ? "USER" : "ASSISTANT"
                try await sendEvent(NovaSonicEvent.textContent(
                    contentId: UUID().uuidString,
                    promptId: promptId,
                    role: role,
                    text: text
                ))
            }
        }

        // Start audio content stream
        try await sendEvent(NovaSonicEvent.audioContentStart(
            contentId: contentId,
            promptId: promptId
        ))
    }

    public func stop() async {
        try? await sendEvent(NovaSonicEvent.audioContentEnd(contentId: contentId, promptId: promptId))
        try? await sendEvent(NovaSonicEvent.promptEnd(promptId: promptId))
        try? await sendEvent(NovaSonicEvent.sessionEnd(sessionId: sessionId))

        inputContinuation?.finish()
        inputContinuation = nil
        outputBody = nil
    }

    public func send(_ event: BidiInputEvent) async throws {
        switch event {
        case .audio(let data, _):
            try await sendEvent(NovaSonicEvent.audioChunk(
                contentId: contentId, promptId: promptId, audioData: data
            ))

        case .text(let text):
            let textId = UUID().uuidString
            try await sendEvent(NovaSonicEvent.textContent(
                contentId: textId, promptId: promptId, role: "USER", text: text
            ))

        case .interrupt:
            break

        case .end:
            try await sendEvent(NovaSonicEvent.audioContentEnd(
                contentId: contentId, promptId: promptId
            ))
            try await sendEvent(NovaSonicEvent.promptEnd(promptId: promptId))

        case .sessionUpdate, .image:
            break
        }
    }

    public func sendToolResult(_ result: ToolResultBlock) async throws {
        let content = result.content.compactMap { c -> String? in
            if case .text(let t) = c { return t }
            return nil
        }.joined()

        try await sendEvent(NovaSonicEvent.toolResult(
            contentId: UUID().uuidString, promptId: promptId,
            toolUseId: result.toolUseId, content: content,
            status: result.status == .success ? "success" : "error"
        ))
    }

    public func receive() -> AsyncThrowingStream<BidiOutputEvent, Error> {
        guard let body = outputBody else {
            return AsyncThrowingStream { $0.finish() }
        }

        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                continuation.yield(.connectionStarted(connectionId: self.sessionId))

                // Set up timeout detection
                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(self.connectionTimeout))
                    continuation.finish(throwing: BidiModelTimeoutError())
                }

                do {
                    for try await event in body {
                        guard case .chunk(let part) = event,
                              let bytes = part.bytes,
                              !bytes.isEmpty
                        else { continue }

                        // Parse the JSON event from the output bytes
                        self.parseAndYield(data: bytes, continuation: continuation)
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

    // MARK: - Event Parsing

    func parseAndYield(
        data: Data,
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

        // Tool use request
        if let toolUse = event["toolUse"] as? [String: Any],
           let toolName = toolUse["toolName"] as? String,
           let toolUseId = toolUse["toolUseId"] as? String {
            let inputStr = toolUse["content"] as? String ?? "{}"
            let input: JSONValue
            if let inputData = inputStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: inputData) {
                input = decoded
            } else {
                input = .object([:])
            }
            continuation.yield(.toolCall(ToolUseBlock(
                toolUseId: toolUseId, name: toolName, input: input
            )))
        }

        // Content end (completion or interruption)
        if let contentEnd = event["contentEnd"] as? [String: Any] {
            let stopReason = contentEnd["stopReason"] as? String
            if stopReason == "INTERRUPTED" {
                continuation.yield(.interruption(reason: .userSpeech))
            }
            continuation.yield(.responseDone(responseId: UUID().uuidString))
        }

        // Usage metrics
        if let usage = event["usage"] as? [String: Any] {
            continuation.yield(.usage(Usage(
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                totalTokens: (usage["inputTokens"] as? Int ?? 0) + (usage["outputTokens"] as? Int ?? 0)
            )))
        }
    }

    // MARK: - Private

    private func sendEvent(_ event: NovaSonicEvent) async throws {
        let data = try event.serialize()
        inputContinuation?.yield(.chunk(
            BedrockRuntimeClientTypes.BidirectionalInputPayloadPart(bytes: data)
        ))
    }
}

// MARK: - Nova Sonic Event Serialization

enum NovaSonicEvent {
    case sessionStart(sessionId: String)
    case sessionEnd(sessionId: String)
    case promptStart(promptId: String, systemPrompt: String?, tools: [ToolSpec], voice: String = "tiffany")
    case promptEnd(promptId: String)
    case audioContentStart(contentId: String, promptId: String)
    case audioContentEnd(contentId: String, promptId: String)
    case audioChunk(contentId: String, promptId: String, audioData: Data)
    case textContent(contentId: String, promptId: String, role: String, text: String)
    case toolResult(contentId: String, promptId: String, toolUseId: String, content: String, status: String)

    func serialize() throws -> Data {
        let event: [String: Any]

        switch self {
        case .sessionStart(let sessionId):
            event = [
                "event": [
                    "sessionStart": [
                        "inferenceConfiguration": [
                            "maxTokens": 1024,
                            "topP": 0.9,
                            "temperature": 0.7,
                        ],
                    ],
                ] as [String: Any],
                "sessionId": sessionId,
            ]

        case .sessionEnd(let sessionId):
            event = ["event": ["sessionEnd": [:] as [String: Any]], "sessionId": sessionId]

        case .promptStart(let promptId, let systemPrompt, let tools, let voice):
            var audioOut: [String: Any] = [
                "mediaType": "audio/lpcm",
                "sampleRateHertz": 16000,
                "sampleSizeBits": 16,
                "channelCount": 1,
            ]
            audioOut["voiceId"] = voice

            var promptConfig: [String: Any] = [
                "audioInputConfiguration": [
                    "mediaType": "audio/lpcm",
                    "sampleRateHertz": 16000,
                    "sampleSizeBits": 16,
                    "channelCount": 1,
                ],
                "audioOutputConfiguration": audioOut,
                "textInputConfiguration": ["mediaType": "text/plain"],
            ]

            if let sys = systemPrompt {
                promptConfig["systemPrompt"] = sys
            }

            if !tools.isEmpty {
                promptConfig["toolConfiguration"] = [
                    "tools": tools.map { spec in
                        [
                            "toolSpec": [
                                "name": spec.name,
                                "description": spec.description,
                                "inputSchema": ["json": "{\"type\":\"object\"}"],
                            ],
                        ]
                    },
                ]
            }

            event = ["event": [
                "promptStart": [
                    "promptId": promptId,
                    "inferenceConfiguration": promptConfig,
                ],
            ]]

        case .promptEnd(let promptId):
            event = ["event": ["promptEnd": ["promptId": promptId]]]

        case .audioContentStart(let contentId, let promptId):
            event = ["event": [
                "contentStart": [
                    "contentId": contentId,
                    "promptId": promptId,
                    "type": "AUDIO",
                    "interactive": true,
                ],
            ]]

        case .audioContentEnd(let contentId, let promptId):
            event = ["event": ["contentEnd": ["contentId": contentId, "promptId": promptId]]]

        case .audioChunk(let contentId, let promptId, let audioData):
            event = ["event": [
                "audioInput": [
                    "contentId": contentId,
                    "promptId": promptId,
                    "audio": audioData.base64EncodedString(),
                ],
            ]]

        case .textContent(let contentId, let promptId, let role, let text):
            event = ["event": [
                "textInput": [
                    "contentId": contentId,
                    "promptId": promptId,
                    "role": role,
                    "content": text,
                ],
            ]]

        case .toolResult(let contentId, let promptId, let toolUseId, let content, let status):
            event = ["event": [
                "toolResult": [
                    "contentId": contentId,
                    "promptId": promptId,
                    "toolUseId": toolUseId,
                    "content": content,
                    "status": status,
                ],
            ]]
        }

        return try JSONSerialization.data(withJSONObject: event)
    }
}
