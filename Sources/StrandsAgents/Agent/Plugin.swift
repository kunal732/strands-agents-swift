/// Protocol for extending agent behavior.
///
/// Plugins can register hooks, provide tools, and configure the agent during initialization.
///
/// ```swift
/// struct LoggingPlugin: AgentPlugin {
///     func configure(agent: Agent) {
///         agent.hookRegistry.addCallback(BeforeModelCallEvent.self) { event in
///             print("Calling model with \(event.messages.count) messages")
///         }
///     }
/// }
///
/// let agent = Agent(model: provider, plugins: [LoggingPlugin()])
/// ```
public protocol AgentPlugin: Sendable {
    /// Called during agent initialization.
    /// Use this to register hooks, add tools, or configure the agent.
    func configure(agent: Agent)

    /// Optional: provide additional tools to register with the agent.
    var tools: [any AgentTool] { get }
}

// MARK: - Default Implementations

extension AgentPlugin {
    public var tools: [any AgentTool] { [] }
}
