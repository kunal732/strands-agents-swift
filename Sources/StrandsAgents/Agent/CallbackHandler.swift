import Foundation

/// Protocol for handling streaming events from the agent loop.
///
/// Callback handlers receive events as they happen during agent execution,
/// enabling real-time output, logging, or custom processing.
///
/// ```swift
/// let agent = Agent(
///     model: provider,
///     callbackHandler: PrintingCallbackHandler()
/// )
/// ```
public protocol CallbackHandler: Sendable {
    /// Called when a text delta is received from the model.
    func onTextDelta(_ text: String) async

    /// Called when a complete content block finishes assembling.
    func onContentBlock(_ block: ContentBlock) async

    /// Called when a tool result is produced.
    func onToolResult(_ result: ToolResultBlock) async

    /// Called when a complete model message is assembled.
    func onModelMessage(_ message: Message) async

    /// Called when the agent produces a final result.
    func onResult(_ result: AgentResult) async
}

// MARK: - Default Implementations

extension CallbackHandler {
    public func onTextDelta(_ text: String) async {}
    public func onContentBlock(_ block: ContentBlock) async {}
    public func onToolResult(_ result: ToolResultBlock) async {}
    public func onModelMessage(_ message: Message) async {}
    public func onResult(_ result: AgentResult) async {}
}

// MARK: - PrintingCallbackHandler

/// A callback handler that prints streaming text to stdout.
///
/// Outputs text deltas as they arrive and prints tool results and
/// completion info on separate lines.
public struct PrintingCallbackHandler: CallbackHandler {
    /// Whether to print tool results.
    public var showToolResults: Bool
    /// Whether to print completion info (stop reason, usage).
    public var showCompletionInfo: Bool

    public init(showToolResults: Bool = true, showCompletionInfo: Bool = true) {
        self.showToolResults = showToolResults
        self.showCompletionInfo = showCompletionInfo
    }

    public func onTextDelta(_ text: String) async {
        print(text, terminator: "")
        fflush(stdout)
    }

    public func onToolResult(_ result: ToolResultBlock) async {
        guard showToolResults else { return }
        let content = result.content.map { c -> String in
            switch c {
            case .text(let t): return t
            case .json(let v): return "\(v)"
            case .image, .document: return "[media]"
            }
        }.joined(separator: ", ")
        let status = result.status == .success ? "OK" : "ERROR"
        print("\n[\(status)] \(content)")
    }

    public func onResult(_ result: AgentResult) async {
        guard showCompletionInfo else { return }
        print("\n--- \(result.stopReason) | \(result.usage.inputTokens)in/\(result.usage.outputTokens)out | \(result.cycleCount) cycles ---")
    }
}

// MARK: - CompositeCallbackHandler

/// Combines multiple callback handlers, dispatching events to all of them.
public struct CompositeCallbackHandler: CallbackHandler {
    private let handlers: [any CallbackHandler]

    public init(_ handlers: [any CallbackHandler]) {
        self.handlers = handlers
    }

    public func onTextDelta(_ text: String) async {
        for h in handlers { await h.onTextDelta(text) }
    }

    public func onContentBlock(_ block: ContentBlock) async {
        for h in handlers { await h.onContentBlock(block) }
    }

    public func onToolResult(_ result: ToolResultBlock) async {
        for h in handlers { await h.onToolResult(result) }
    }

    public func onModelMessage(_ message: Message) async {
        for h in handlers { await h.onModelMessage(message) }
    }

    public func onResult(_ result: AgentResult) async {
        for h in handlers { await h.onResult(result) }
    }
}

/// A callback handler that does nothing. Used as the default.
public struct NullCallbackHandler: CallbackHandler {
    public init() {}
}
