import Foundation

/// Fully local bidirectional model using MLX Audio + MLX LLM.
///
/// Runs a pipeline of: **Mic -> VAD -> STT -> LLM -> TTS -> Speaker**
///
/// All processing happens on-device using Apple Silicon. No network required.
///
/// ```swift
/// let model = LocalBidiModel(
///     stt: MyWhisperSTT(),
///     llm: MyMLXLLM(),
///     tts: MySopranoTTS()
/// )
///
/// let agent = BidiAgent(model: model, tools: [WeatherTool()])
/// let session = try await agent.start()
/// ```
///
/// Implement `STTProcessor`, `LLMProcessor`, and `TTSProcessor` using
/// `mlx-audio-swift` models for fully on-device voice agents.
public final class LocalBidiModel: BidiModel, @unchecked Sendable {
    public var modelId: String? { "local-bidi-pipeline" }
    public var config: [String: Any] {
        [
            "audio": [
                "input_rate": 16000,
                "output_rate": 16000,
                "channels": 1,
                "format": "pcm16",
            ] as [String: Any],
        ]
    }

    private let stt: any STTProcessor
    private let llm: any LLMProcessor
    private let tts: any TTSProcessor
    private let vad: (any VADProcessor)?

    private var eventContinuation: AsyncThrowingStream<BidiOutputEvent, Error>.Continuation?
    private var systemPrompt: String?
    private var tools: [ToolSpec] = []
    private var conversationHistory: [Message] = []
    private let historyLock = NSLock()
    private var isProcessing = false

    public init(
        stt: any STTProcessor,
        llm: any LLMProcessor,
        tts: any TTSProcessor,
        vad: (any VADProcessor)? = nil
    ) {
        self.stt = stt
        self.llm = llm
        self.tts = tts
        self.vad = vad
    }

    public func start(systemPrompt: String?, tools: [ToolSpec], messages: [Message]) async throws {
        self.systemPrompt = systemPrompt
        self.tools = tools
        historyLock.withLock { conversationHistory = messages }
    }

    public func stop() async {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    public func send(_ event: BidiInputEvent) async throws {
        switch event {
        case .audio(let data, let format):
            // VAD check
            if let vad {
                let hasSpeech = try await vad.detectSpeech(audio: data, format: format)
                if !hasSpeech { return }
            }

            eventContinuation?.yield(.inputSpeechStarted)

            let transcript = try await stt.transcribe(audio: data, format: format)
            guard !transcript.isEmpty else { return }

            eventContinuation?.yield(.inputSpeechDone(transcript: transcript))
            eventContinuation?.yield(.transcript(role: .user, text: transcript, isFinal: true))

            await processInput(transcript)

        case .text(let text):
            eventContinuation?.yield(.transcript(role: .user, text: text, isFinal: true))
            await processInput(text)

        case .interrupt:
            isProcessing = false

        case .end:
            eventContinuation?.yield(.sessionEnded(reason: .complete))
            eventContinuation?.finish()

        case .sessionUpdate, .image:
            break
        }
    }

    public func sendToolResult(_ result: ToolResultBlock) async throws {
        // Tool results are handled inline by BidiAgent
        let content = result.content.compactMap { c -> String? in
            if case .text(let t) = c { return t }
            return nil
        }.joined()

        historyLock.withLock {
            conversationHistory.append(Message(role: .user, content: [.toolResult(result)]))
        }

        // Continue generation with tool result
        await processInput("[Tool result: \(content)]")
    }

    public func receive() -> AsyncThrowingStream<BidiOutputEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<BidiOutputEvent, Error>.makeStream()
        self.eventContinuation = continuation
        continuation.yield(.connectionStarted(connectionId: UUID().uuidString))
        return stream
    }

    // MARK: - Private

    private func processInput(_ text: String) async {
        guard !isProcessing else { return }
        isProcessing = true

        let responseId = UUID().uuidString
        historyLock.withLock { conversationHistory.append(.user(text)) }
        eventContinuation?.yield(.responseStarted(responseId: responseId))

        // LLM generate
        var fullResponse = ""
        let messages = historyLock.withLock { conversationHistory }
        let stream = llm.generate(messages: messages, systemPrompt: systemPrompt, tools: tools)

        do {
            for try await chunk in stream {
                guard isProcessing else { break }
                fullResponse += chunk
                eventContinuation?.yield(.textDelta(chunk))
            }
        } catch {
            eventContinuation?.yield(.error(error.localizedDescription))
            isProcessing = false
            return
        }

        historyLock.withLock { conversationHistory.append(.assistant(fullResponse)) }
        eventContinuation?.yield(.transcript(role: .assistant, text: fullResponse, isFinal: true))

        // TTS
        let audioStream = tts.synthesize(text: fullResponse, voice: nil)
        do {
            for try await audioChunk in audioStream {
                guard isProcessing else { break }
                eventContinuation?.yield(.audio(audioChunk, format: .mlxDefault))
            }
        } catch {
            eventContinuation?.yield(.error(error.localizedDescription))
        }

        eventContinuation?.yield(.responseDone(responseId: responseId))
        isProcessing = false
    }
}

// MARK: - Pipeline Processor Protocols

/// Speech-to-text processor.
public protocol STTProcessor: Sendable {
    func transcribe(audio: Data, format: AudioFormat) async throws -> String
}

/// Language model processor for generating text responses.
public protocol LLMProcessor: Sendable {
    func generate(messages: [Message], systemPrompt: String?, tools: [ToolSpec]) -> AsyncThrowingStream<String, Error>
}

/// Text-to-speech processor.
public protocol TTSProcessor: Sendable {
    func synthesize(text: String, voice: String?) -> AsyncThrowingStream<Data, Error>
}

/// Voice activity detection processor.
public protocol VADProcessor: Sendable {
    func detectSpeech(audio: Data, format: AudioFormat) async throws -> Bool
}

// MARK: - Configuration

/// Configuration for the local bidi pipeline.
public struct LocalBidiConfig: Sendable {
    public var sttModelId: String
    public var llmModelId: String
    public var ttsModelId: String
    public var vadModelId: String?
    public var maxTokens: Int

    public init(
        sttModelId: String = "mlx-community/GLM-ASR-Nano-2512-4bit",
        llmModelId: String = "mlx-community/Qwen3-8B-4bit",
        ttsModelId: String = "mlx-community/Soprano-80M-bf16",
        vadModelId: String? = nil,
        maxTokens: Int = 512
    ) {
        self.sttModelId = sttModelId
        self.llmModelId = llmModelId
        self.ttsModelId = ttsModelId
        self.vadModelId = vadModelId
        self.maxTokens = maxTokens
    }
}
