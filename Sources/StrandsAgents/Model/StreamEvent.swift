/// Events emitted by a model provider during streaming.
///
/// This mirrors the Bedrock/Anthropic streaming event model. All providers must
/// translate their native streaming format into these events.
public enum ModelStreamEvent: Sendable {
    /// The start of a new message.
    case messageStart(role: Role)

    /// The start of a new content block within the message.
    case contentBlockStart(ContentBlockStartData)

    /// An incremental delta for the current content block.
    case contentBlockDelta(ContentBlockDelta)

    /// The current content block is complete.
    case contentBlockStop

    /// The message is complete.
    case messageStop(stopReason: StopReason)

    /// Metadata about the invocation (token usage, latency).
    case metadata(usage: Usage?, metrics: InvocationMetrics?)
}

/// Data for the start of a content block (used to identify tool use blocks).
public struct ContentBlockStartData: Sendable {
    /// If this is a tool use block, provides the tool name and ID.
    public var toolUse: ToolUseStart?

    public init(toolUse: ToolUseStart? = nil) {
        self.toolUse = toolUse
    }
}

public struct ToolUseStart: Sendable {
    public var toolUseId: String
    public var name: String

    public init(toolUseId: String, name: String) {
        self.toolUseId = toolUseId
        self.name = name
    }
}

/// Incremental content within a streaming content block.
public enum ContentBlockDelta: Sendable {
    case text(String)
    case toolUseInput(String)
    case reasoning(text: String?, signature: String?)
    case citations([Citation])
}
