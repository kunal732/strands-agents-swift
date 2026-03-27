/// Events yielded by `Agent.stream()` during execution.
public enum AgentStreamEvent: Sendable {
    /// A text token from the model's visible response (outside any <think> block).
    case textDelta(String)

    /// A text token from inside a <think>...</think> reasoning block.
    /// Only emitted by models that support extended thinking (e.g. Qwen3).
    /// Use this to show the model's reasoning in a separate UI element.
    case thinkingDelta(String)

    /// A complete content block from the model.
    case contentBlock(ContentBlock)

    /// A tool result after tool execution.
    case toolResult(ToolResultBlock)

    /// The complete model message (after all content blocks).
    case modelMessage(Message)

    /// The final agent result.
    case result(AgentResult)
}
