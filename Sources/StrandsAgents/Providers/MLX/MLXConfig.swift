import Foundation

/// Configuration for the MLX local model provider.
public struct MLXConfig: Sendable {
    /// HuggingFace model ID (e.g. "mlx-community/Qwen3-4B-4bit").
    public var modelId: String

    /// Maximum tokens to generate.
    public var maxTokens: Int

    /// Sampling temperature.
    public var temperature: Double

    /// Top-p nucleus sampling.
    public var topP: Double

    /// Repetition penalty.
    public var repetitionPenalty: Double?

    /// Number of recent tokens to consider for repetition penalty.
    public var repetitionContextSize: Int?

    /// Optional callback reporting model download/load progress (0.0 → 1.0).
    /// Called on an arbitrary background thread. If the model is already cached
    /// this callback is not invoked.
    public var onDownloadProgress: (@Sendable (Double) -> Void)?

    public init(
        modelId: String = "mlx-community/Qwen3-4B-4bit",
        maxTokens: Int = 2048,
        temperature: Double = 0.7,
        topP: Double = 0.9,
        repetitionPenalty: Double? = nil,
        repetitionContextSize: Int? = nil,
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.modelId = modelId
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.onDownloadProgress = onDownloadProgress
    }
}
