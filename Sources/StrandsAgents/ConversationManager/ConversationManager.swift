/// Manages conversation history length and context window usage.
///
/// Called after each agent loop cycle to trim or summarize messages.
/// Also called when a context window overflow occurs.
public protocol ConversationManager: Sendable {
    /// Apply management strategy to the message history.
    ///
    /// Called after each event loop cycle. May trim, summarize, or otherwise
    /// modify the message array to stay within context limits.
    func applyManagement(messages: inout [Message]) async

    /// Reduce context when the model's context window is exceeded.
    ///
    /// Called when a context overflow error is caught. Must reduce the
    /// message array enough to fit within the model's context window.
    ///
    /// - Throws: `StrandsError.contextWindowOverflow` if context cannot be reduced further.
    func reduceContext(messages: inout [Message], error: Error?) async throws
}
