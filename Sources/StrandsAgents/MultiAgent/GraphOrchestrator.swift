import Foundation

/// A node in a multi-agent graph.
public struct GraphNode: Sendable {
    /// Unique identifier for this node.
    public let id: String

    /// The agent that executes at this node.
    public let agent: Agent

    /// IDs of nodes that must complete before this node can execute.
    public let dependencies: Set<String>

    /// Optional prompt override. If nil, uses the output of dependency nodes.
    public let prompt: String?

    public init(
        id: String,
        agent: Agent,
        dependencies: Set<String> = [],
        prompt: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.dependencies = dependencies
        self.prompt = prompt
    }
}

/// A conditional edge between nodes in a graph.
public struct GraphEdge: Sendable {
    public let from: String
    public let to: String
    /// Optional condition. If nil, the edge is always followed.
    public let condition: (@Sendable ([String: AgentResult]) -> Bool)?

    public init(from: String, to: String, condition: (@Sendable ([String: AgentResult]) -> Bool)? = nil) {
        self.from = from
        self.to = to
        self.condition = condition
    }
}

/// DAG-based multi-agent orchestrator.
///
/// Nodes execute in topological order respecting dependencies. Nodes within the same
/// dependency tier execute in parallel. Results from completed nodes are propagated
/// as input to downstream nodes.
///
/// ```swift
/// let researcher = Agent(model: provider, systemPrompt: "You are a researcher...")
/// let writer = Agent(model: provider, systemPrompt: "You are a writer...")
///
/// let graph = GraphOrchestrator(nodes: [
///     GraphNode(id: "research", agent: researcher),
///     GraphNode(id: "write", agent: writer, dependencies: ["research"]),
/// ])
///
/// let result = try await graph.run("Write about quantum computing")
/// ```
public final class GraphOrchestrator: @unchecked Sendable {
    private let nodes: [String: GraphNode]
    private let edges: [GraphEdge]
    private let hookRegistry: HookRegistry
    public let maxNodeExecutions: Int

    public init(
        nodes: [GraphNode],
        edges: [GraphEdge] = [],
        hookRegistry: HookRegistry = HookRegistry(),
        maxNodeExecutions: Int = 10
    ) {
        var nodeMap: [String: GraphNode] = [:]
        for node in nodes { nodeMap[node.id] = node }
        self.nodes = nodeMap
        self.edges = edges
        self.hookRegistry = hookRegistry
        self.maxNodeExecutions = maxNodeExecutions
    }

    /// Execute the graph with the given input.
    public func run(_ input: String) async throws -> MultiAgentResult {
        let observability = nodes.values.first?.agent.observability ?? NoOpObservabilityEngine()
        let rootSpan = observability.startSpan(name: "invoke_graph", attributes: [
            GenAIAttributes.operationName: "invoke_graph",
            GenAIAttributes.eventStartTime: ISO8601DateFormatter().string(from: Date()),
        ])
        defer { observability.endSpan(rootSpan, status: .ok) }

        var nodeResults: [String: AgentResult] = [:]
        var executionOrder: [String] = []
        var totalUsage = Usage()
        var executionCounts: [String: Int] = [:]

        // Find entry points (nodes with no dependencies)
        var readyNodes = nodes.values.filter { $0.dependencies.isEmpty }.map(\.id)

        while !readyNodes.isEmpty {
            // Execute ready nodes in parallel
            let results = try await withThrowingTaskGroup(
                of: (String, AgentResult).self
            ) { group in
                for nodeId in readyNodes {
                    guard let node = nodes[nodeId] else { continue }

                    let count = executionCounts[nodeId, default: 0]
                    guard count < maxNodeExecutions else { continue }
                    executionCounts[nodeId] = count + 1

                    // Capture values before the task to avoid data race
                    let nodeInput: String
                    if let prompt = node.prompt {
                        nodeInput = prompt
                    } else if !node.dependencies.isEmpty {
                        let depOutputs = node.dependencies.compactMap { depId in
                            nodeResults[depId]?.message.textContent
                        }
                        nodeInput = depOutputs.isEmpty ? input : depOutputs.joined(separator: "\n\n")
                    } else {
                        nodeInput = input
                    }

                    group.addTask {
                        let result = try await node.agent.run(nodeInput)
                        return (nodeId, result)
                    }
                }

                var batchResults: [(String, AgentResult)] = []
                for try await pair in group {
                    batchResults.append(pair)
                }
                return batchResults
            }

            // Record results
            for (nodeId, result) in results {
                nodeResults[nodeId] = result
                executionOrder.append(nodeId)
                totalUsage.inputTokens += result.usage.inputTokens
                totalUsage.outputTokens += result.usage.outputTokens
                totalUsage.totalTokens += result.usage.totalTokens
            }

            let completedIds = Set(results.map(\.0))

            // Find next ready nodes
            readyNodes = []
            for (id, node) in nodes where nodeResults[id] == nil {
                // All dependencies must be completed
                if node.dependencies.allSatisfy({ nodeResults[$0] != nil }) {
                    // Check edge conditions
                    let edgesTo = edges.filter { $0.to == id }
                    if edgesTo.isEmpty || edgesTo.contains(where: { $0.condition?(nodeResults) ?? true }) {
                        readyNodes.append(id)
                    }
                }
            }

            // Emit handoff events
            for nextId in readyNodes {
                for completedId in completedIds {
                    try await hookRegistry.invoke(MultiAgentHandoffEvent(
                        fromNode: completedId,
                        toNode: nextId
                    ))
                }
            }
        }

        return MultiAgentResult(
            nodeResults: nodeResults,
            executionOrder: executionOrder,
            totalUsage: totalUsage,
            finalResult: executionOrder.last.flatMap { nodeResults[$0] }
        )
    }
}
