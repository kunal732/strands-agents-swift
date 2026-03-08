/// Events yielded by `Agent.stream()` during execution.
public enum AgentStreamEvent: Sendable {
    /// A text delta from the model (for live display).
    case textDelta(String)

    /// A complete content block from the model.
    case contentBlock(ContentBlock)

    /// A tool result after tool execution.
    case toolResult(ToolResultBlock)

    /// The complete model message (after all content blocks).
    case modelMessage(Message)

    /// The final agent result.
    case result(AgentResult)
}
