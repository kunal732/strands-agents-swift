/// Configuration for prompt caching behavior.
///
/// Controls where cache points are inserted in the system prompt and messages
/// to enable prompt caching on supported providers (Anthropic, Bedrock).
///
/// ```swift
/// let agent = Agent(
///     model: provider,
///     systemPrompt: "You are a helpful assistant with a large knowledge base...",
///     cacheConfig: .auto
/// )
/// ```
public enum CacheConfig: Sendable {
    /// No caching. Default behavior.
    case none

    /// Automatically insert cache points at optimal positions.
    /// Places a cache point after the system prompt and after tool definitions.
    case auto

    /// Insert cache points at specific positions.
    case manual(positions: [CachePosition])
}

/// Where to insert a cache point.
public enum CachePosition: Sendable {
    /// After the system prompt.
    case afterSystemPrompt

    /// After tool definitions.
    case afterToolDefinitions

    /// After the Nth message from the start.
    case afterMessage(index: Int)
}
