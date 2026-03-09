import Foundation

/// Configuration for the AWS Bedrock model provider.
public struct BedrockConfig: Sendable {
    /// The Bedrock model ID or inference profile ID.
    ///
    /// Use an inference profile ID (e.g. "us.anthropic.claude-sonnet-4-20250514-v1:0")
    /// for on-demand throughput, or a provisioned model ARN.
    public var modelId: String

    /// AWS region (e.g. "us-east-1").
    public var region: String

    /// Maximum tokens to generate.
    public var maxTokens: Int

    /// Sampling temperature (0.0 - 1.0).
    public var temperature: Double?

    /// Top-p nucleus sampling.
    public var topP: Double?

    /// Optional stop sequences.
    public var stopSequences: [String]?

    public init(
        modelId: String = "us.anthropic.claude-sonnet-4-20250514-v1:0",
        region: String = "us-east-1",
        maxTokens: Int = 4096,
        temperature: Double? = nil,
        topP: Double? = nil,
        stopSequences: [String]? = nil
    ) {
        self.modelId = modelId
        self.region = region
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
    }
}
