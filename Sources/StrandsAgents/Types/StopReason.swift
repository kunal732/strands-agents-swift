/// The reason the model stopped generating.
public enum StopReason: String, Sendable, Codable, Hashable {
    /// Model finished its response naturally.
    case endTurn = "end_turn"

    /// Model requested one or more tool invocations.
    case toolUse = "tool_use"

    /// Output was truncated due to max token limit.
    case maxTokens = "max_tokens"

    /// A stop sequence was encountered.
    case stopSequence = "stop_sequence"

    /// Content was filtered by a safety policy.
    case contentFiltered = "content_filtered"

    /// A guardrail intervened.
    case guardrailIntervened = "guardrail_intervened"
}
