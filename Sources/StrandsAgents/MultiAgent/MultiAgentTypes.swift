import Foundation

/// Status of a multi-agent node during execution.
public enum NodeStatus: Sendable {
    case pending
    case executing
    case completed(AgentResult)
    case failed(Error)
}

/// Result from a multi-agent orchestration.
public struct MultiAgentResult: Sendable {
    /// Results from each node, keyed by node ID.
    public var nodeResults: [String: AgentResult]

    /// The execution order of nodes.
    public var executionOrder: [String]

    /// Aggregated token usage across all nodes.
    public var totalUsage: Usage

    /// The final result (from the last completed node).
    public var finalResult: AgentResult?

    public init(
        nodeResults: [String: AgentResult] = [:],
        executionOrder: [String] = [],
        totalUsage: Usage = Usage(),
        finalResult: AgentResult? = nil
    ) {
        self.nodeResults = nodeResults
        self.executionOrder = executionOrder
        self.totalUsage = totalUsage
        self.finalResult = finalResult
    }
}

extension MultiAgentResult: CustomStringConvertible {
    public var description: String {
        finalResult?.message.textContent ?? ""
    }
}

/// Events emitted during multi-agent orchestration.
public struct MultiAgentHandoffEvent: HookEvent {
    public var fromNode: String
    public var toNode: String
    public var message: String?

    public init(fromNode: String, toNode: String, message: String? = nil) {
        self.fromNode = fromNode
        self.toNode = toNode
        self.message = message
    }
}
