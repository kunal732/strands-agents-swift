/// Abstract interface for a model that can generate responses.
///
/// All model providers (Bedrock, MLX, Anthropic, OpenAI, etc.) conform to this protocol.
/// Providers translate their native streaming format into the common `ModelStreamEvent` sequence.
///
/// ## Stream Contract
///
/// A well-formed stream produces events in this order:
/// ```
/// messageStart
/// (contentBlockStart, contentBlockDelta*, contentBlockStop)*
/// messageStop
/// metadata?
/// ```
public protocol ModelProvider: Sendable {
    /// A human-readable identifier for this model (e.g. "us.anthropic.claude-sonnet-4-20250514-v1:0").
    var modelId: String? { get }

    /// The OTel GenAI system identifier for this provider (e.g. "aws.bedrock", "anthropic", "openai").
    var genAISystem: String { get }

    /// Stream a conversation with the model.
    ///
    /// - Parameters:
    ///   - messages: The conversation history.
    ///   - toolSpecs: Tool specifications the model may use. Pass nil to disable tool use.
    ///   - systemPrompt: Optional system prompt.
    ///   - toolChoice: Optional control over tool selection.
    /// - Returns: An async stream of model events.
    func stream(
        messages: [Message],
        toolSpecs: [ToolSpec]?,
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

/// A model provider that supports runtime configuration updates.
///
/// Providers that conform to this protocol allow callers to inspect and modify
/// their configuration at runtime (e.g. changing temperature, max tokens).
public protocol ConfigurableModelProvider: ModelProvider {
    associatedtype Config: Sendable

    /// Get the current configuration.
    func getConfig() -> Config

    /// Update the configuration.
    func updateConfig(_ config: Config)
}

// MARK: - Default Parameters

extension ModelProvider {
    /// Default GenAI system -- providers override this with their specific value.
    public var genAISystem: String { "unknown" }
}

extension ModelProvider {
    /// Convenience overload with defaults for optional parameters.
    public func stream(
        messages: [Message],
        toolSpecs: [ToolSpec]? = nil,
        systemPrompt: String? = nil,
        toolChoice: ToolChoice? = nil
    ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        stream(messages: messages, toolSpecs: toolSpecs, systemPrompt: systemPrompt, toolChoice: toolChoice)
    }
}
