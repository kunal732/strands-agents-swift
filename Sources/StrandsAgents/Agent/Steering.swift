import Foundation

/// A steering handler that provides contextual guidance to the agent.
///
/// Unlike static system prompts, steering handlers inject just-in-time guidance
/// based on the current context -- the conversation so far, which tools have been
/// called, and any external context providers.
///
/// ```swift
/// struct ApprovalSteering: SteeringHandler {
///     func evaluate(context: SteeringContext) -> SteeringAction {
///         if context.lastToolCall == "delete_files" {
///             return .guide("Before deleting files, confirm with the user.")
///         }
///         return .proceed
///     }
/// }
///
/// let agent = Agent(model: provider, steeringHandlers: [ApprovalSteering()])
/// ```
public protocol SteeringHandler: Sendable {
    /// Evaluate the current context and decide on an action.
    func evaluate(context: SteeringContext) async -> SteeringAction
}

/// The action a steering handler recommends.
public enum SteeringAction: Sendable {
    /// Proceed normally -- no guidance needed.
    case proceed

    /// Inject guidance text into the system prompt for this turn.
    case guide(String)

    /// Interrupt execution and request human input.
    case interrupt(reason: String)
}

/// Context provided to a steering handler for evaluation.
public struct SteeringContext: Sendable {
    /// The current conversation messages.
    public var messages: [Message]

    /// The system prompt.
    public var systemPrompt: String?

    /// The name of the last tool that was called, if any.
    public var lastToolCall: String?

    /// The names of all tools called so far in this invocation.
    public var toolCallHistory: [String]

    /// The current cycle number.
    public var cycleNumber: Int

    /// Custom context values from context providers.
    public var customContext: [String: JSONValue]

    public init(
        messages: [Message] = [],
        systemPrompt: String? = nil,
        lastToolCall: String? = nil,
        toolCallHistory: [String] = [],
        cycleNumber: Int = 0,
        customContext: [String: JSONValue] = [:]
    ) {
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.lastToolCall = lastToolCall
        self.toolCallHistory = toolCallHistory
        self.cycleNumber = cycleNumber
        self.customContext = customContext
    }
}

/// Provides dynamic context values to steering handlers.
///
/// Context providers are called before each steering evaluation to supply
/// up-to-date context (e.g. user preferences, time of day, feature flags).
public protocol SteeringContextProvider: Sendable {
    /// The key under which this context is stored.
    var key: String { get }

    /// Provide the current context value.
    func provide() async -> JSONValue
}

/// An LLM-based steering handler that uses a model to generate guidance.
///
/// Sends the current context to a model with a steering prompt, and uses
/// the model's response as guidance for the agent.
public struct LLMSteeringHandler: SteeringHandler {
    private let provider: any ModelProvider
    private let steeringPrompt: String

    public init(
        provider: any ModelProvider,
        steeringPrompt: String = "Based on the conversation context, provide brief guidance for the agent's next action. If no guidance is needed, respond with 'PROCEED'."
    ) {
        self.provider = provider
        self.steeringPrompt = steeringPrompt
    }

    public func evaluate(context: SteeringContext) async -> SteeringAction {
        let contextSummary = """
        Cycle: \(context.cycleNumber)
        Tools called: \(context.toolCallHistory.joined(separator: ", "))
        Last message: \(context.messages.last?.textContent ?? "none")
        """

        let messages = [
            Message.user("\(steeringPrompt)\n\nContext:\n\(contextSummary)")
        ]

        let stream = provider.stream(messages: messages)
        do {
            let result = try await StreamAggregator().aggregate(stream: stream)
            let guidance = result.message.textContent
            if guidance.uppercased().contains("PROCEED") {
                return .proceed
            }
            return .guide(guidance)
        } catch {
            return .proceed
        }
    }
}

/// A ledger-based context provider that tracks tool calls.
///
/// Records which tools were called and how many times, making this
/// information available to steering handlers.
public final class LedgerProvider: SteeringContextProvider, @unchecked Sendable {
    public let key = "tool_ledger"
    private var toolCounts: [String: Int] = [:]
    private let lock = NSLock()

    public init() {}

    /// Record a tool call.
    public func recordToolCall(_ name: String) {
        lock.withLock { toolCounts[name, default: 0] += 1 }
    }

    public func provide() async -> JSONValue {
        let counts = lock.withLock { toolCounts }
        return .object(counts.mapValues { .int($0) })
    }
}
