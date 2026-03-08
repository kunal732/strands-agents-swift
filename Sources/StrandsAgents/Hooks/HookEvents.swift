/// Marker protocol for all hookable events.
public protocol HookEvent: Sendable {}

// MARK: - Lifecycle Events

/// Emitted after the agent is fully initialized.
public struct AgentInitializedEvent: HookEvent {
    public init() {}
}

/// Emitted before the agent processes an invocation.
public struct BeforeInvocationEvent: HookEvent {
    public var messages: [Message]

    public init(messages: [Message]) {
        self.messages = messages
    }
}

/// Emitted after the agent completes an invocation.
public struct AfterInvocationEvent: HookEvent {
    public var result: AgentResult

    public init(result: AgentResult) {
        self.result = result
    }
}

/// Emitted when a message is added to conversation history.
public struct MessageAddedEvent: HookEvent {
    public var message: Message

    public init(message: Message) {
        self.message = message
    }
}

// MARK: - Model Events

/// Emitted before a model call.
public struct BeforeModelCallEvent: HookEvent {
    public var messages: [Message]
    public var toolSpecs: [ToolSpec]?

    public init(messages: [Message], toolSpecs: [ToolSpec]?) {
        self.messages = messages
        self.toolSpecs = toolSpecs
    }
}

/// Emitted after a model call completes.
public struct AfterModelCallEvent: HookEvent {
    public var message: Message
    public var stopReason: StopReason
    public var usage: Usage?
    public var error: Error?

    public init(message: Message, stopReason: StopReason, usage: Usage? = nil, error: Error? = nil) {
        self.message = message
        self.stopReason = stopReason
        self.usage = usage
        self.error = error
    }
}

// MARK: - Tool Events

/// Emitted before a tool is called.
public struct BeforeToolCallEvent: HookEvent {
    public var toolUse: ToolUseBlock

    public init(toolUse: ToolUseBlock) {
        self.toolUse = toolUse
    }
}

/// Emitted after a tool call completes.
public struct AfterToolCallEvent: HookEvent {
    public var toolUse: ToolUseBlock
    public var result: ToolResultBlock

    public init(toolUse: ToolUseBlock, result: ToolResultBlock) {
        self.toolUse = toolUse
        self.result = result
    }
}

// MARK: - Routing Events

/// Emitted when a routing decision is made.
public struct RoutingDecisionEvent: HookEvent {
    public var decision: RoutingDecision

    public init(decision: RoutingDecision) {
        self.decision = decision
    }
}
