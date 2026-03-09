/// Context provided to a tool during execution.
///
/// Gives tools access to the conversation history, agent state, and invocation metadata.
public struct ToolContext: Sendable {
    /// The tool invocation details.
    public let toolUse: ToolUseBlock

    /// Read-only snapshot of current conversation messages.
    public let messages: [Message]

    /// The system prompt, if any.
    public let systemPrompt: String?

    /// Arbitrary key-value state shared across invocations.
    public let invocationState: [String: JSONValue]

    /// The agent's persistent state store. Tools can read and write state here.
    public let agentState: AgentState?

    public init(
        toolUse: ToolUseBlock,
        messages: [Message] = [],
        systemPrompt: String? = nil,
        invocationState: [String: JSONValue] = [:],
        agentState: AgentState? = nil
    ) {
        self.toolUse = toolUse
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.invocationState = invocationState
        self.agentState = agentState
    }
}
