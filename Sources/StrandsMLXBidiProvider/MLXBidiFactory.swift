import Foundation
import StrandsAgents
import StrandsBidiStreaming

/// Convenience factory to create a fully local bidi agent with MLX models.
///
/// ```swift
/// let agent = try await MLXBidiFactory.createAgent(
///     sttModelId: "mlx-community/whisper-large-v3-turbo",
///     llmModelId: "mlx-community/Qwen3-8B-4bit",
///     ttsModelId: "mlx-community/Soprano-80M-bf16",
///     tools: [WeatherTool()],
///     systemPrompt: "You are a helpful voice assistant."
/// )
///
/// // Use with microphone + speaker
/// let mic = MicrophoneInput(format: .mlxDefault)
/// let speaker = SpeakerOutput(format: .mlxDefault)
/// try mic.start()
/// try speaker.start()
///
/// try await agent.start()
///
/// Task {
///     for await chunk in mic.audioStream {
///         try await agent.send(.audio(chunk, format: .mlxDefault))
///     }
/// }
///
/// for try await event in agent.receive() {
///     switch event {
///     case .audio(let data, _): speaker.play(data)
///     case .textDelta(let text): print(text, terminator: "")
///     case .transcript(_, let text, true): print("\n[\(text)]")
///     default: break
///     }
/// }
/// ```
public enum MLXBidiFactory {

    /// Create a BidiAgent with all-local MLX models.
    ///
    /// - Parameters:
    ///   - sttModelId: HuggingFace model ID for speech-to-text.
    ///   - llmModelId: HuggingFace model ID for the language model.
    ///   - ttsModelId: HuggingFace model ID for text-to-speech.
    ///   - tools: Tools available to the agent.
    ///   - systemPrompt: System prompt for the LLM.
    ///   - maxTokens: Maximum tokens for LLM generation.
    /// - Returns: A configured `BidiAgent` ready to start.
    ///
    /// - Note: This method does NOT preload models. Call `preload()` on the
    ///   individual processors or the first `send()` will trigger model loading.
    public static func createAgent(
        llmProcessor: any LLMProcessor,
        sttProcessor: any STTProcessor,
        ttsProcessor: any TTSProcessor,
        vadProcessor: (any VADProcessor)? = nil,
        tools: [any AgentTool] = [],
        systemPrompt: String? = nil
    ) -> BidiAgent {
        let model = LocalBidiModel(
            stt: sttProcessor,
            llm: llmProcessor,
            tts: ttsProcessor,
            vad: vadProcessor
        )

        return BidiAgent(
            model: model,
            tools: tools,
            systemPrompt: systemPrompt,
            config: BidiSessionConfig(
                instructions: systemPrompt,
                inputAudioFormat: .mlxDefault,
                outputAudioFormat: .mlxDefault,
                vadEnabled: vadProcessor != nil
            )
        )
    }

    /// Create just the LLM processor for use in custom pipelines.
    public static func createLLMProcessor(
        modelId: String = "mlx-community/Qwen3-8B-4bit",
        maxTokens: Int = 512
    ) -> MLXLLMProcessor {
        MLXLLMProcessor(modelId: modelId, maxTokens: maxTokens)
    }
}
