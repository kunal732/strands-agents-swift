import Foundation
import StrandsAgents
import StrandsBidiStreaming
import StrandsMLXProvider
import MLXLMCommon

/// LLM processor using MLX Swift LM for local text generation.
///
/// Wraps the existing `MLXProvider` to conform to the `LLMProcessor` protocol
/// for use in the local bidi pipeline.
///
/// ```swift
/// let llm = try await MLXLLMProcessor(modelId: "mlx-community/Qwen3-8B-4bit")
/// ```
public final class MLXLLMProcessor: LLMProcessor, @unchecked Sendable {
    private let provider: MLXProvider

    public init(config: MLXConfig = MLXConfig()) {
        self.provider = MLXProvider(config: config)
    }

    public convenience init(modelId: String, maxTokens: Int = 512) {
        self.init(config: MLXConfig(modelId: modelId, maxTokens: maxTokens))
    }

    /// Preload the model into memory.
    public func preload() async throws {
        try await provider.preload()
    }

    public func generate(
        messages: [StrandsAgents.Message],
        systemPrompt: String?,
        tools: [StrandsAgents.ToolSpec]
    ) -> AsyncThrowingStream<String, Error> {
        // Use the MLX provider's stream, extract text deltas
        let modelStream = provider.stream(
            messages: messages,
            toolSpecs: tools.isEmpty ? nil : tools,
            systemPrompt: systemPrompt,
            toolChoice: nil
        )

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await StreamAggregator().aggregate(
                        stream: modelStream,
                        onTextDelta: { text in
                            continuation.yield(text)
                        }
                    )
                    // If there's remaining text not captured by deltas
                    _ = result
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
