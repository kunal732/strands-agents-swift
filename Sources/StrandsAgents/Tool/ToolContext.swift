/// Context provided to a tool during execution.
///
/// Gives tools access to the agent, conversation history, and invocation metadata.
public struct ToolContext: Sendable {
    /// The tool invocation details.
    public let toolUse: ToolUseBlock

    /// Read-only snapshot of current conversation messages.
    public let messages: [Message]

    /// The system prompt, if any.
    public let systemPrompt: String?

    /// Arbitrary key-value state shared across the invocation.
    public let invocationState: [String: JSONValue]

    public init(
        toolUse: ToolUseBlock,
        messages: [Message] = [],
        systemPrompt: String? = nil,
        invocationState: [String: JSONValue] = [:]
    ) {
        self.toolUse = toolUse
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.invocationState = invocationState
    }
}
