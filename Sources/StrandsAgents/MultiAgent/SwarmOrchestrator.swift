import Foundation

/// A member of a swarm -- an agent with a role description.
public struct SwarmMember: Sendable {
    /// Unique identifier / name for this member.
    public let id: String

    /// Description of this member's role (shared with other agents for handoff decisions).
    public let description: String

    /// The agent that executes for this member.
    public let agent: Agent

    public init(id: String, description: String, agent: Agent) {
        self.id = id
        self.description = description
        self.agent = agent
    }
}

/// Collaborative multi-agent orchestrator using autonomous handoffs.
///
/// Agents decide when to hand off to another agent using an injected `handoff_to_agent` tool.
/// Execution continues until an agent completes without issuing a handoff.
///
/// ```swift
/// let researcher = SwarmMember(
///     id: "researcher",
///     description: "Researches topics and gathers information",
///     agent: Agent(model: provider, systemPrompt: "You are a researcher...")
/// )
/// let writer = SwarmMember(
///     id: "writer",
///     description: "Writes polished content from research",
///     agent: Agent(model: provider, systemPrompt: "You are a writer...")
/// )
///
/// let swarm = SwarmOrchestrator(members: [researcher, writer], entryPoint: "researcher")
/// let result = try await swarm.run("Write about quantum computing")
/// ```
public final class SwarmOrchestrator: @unchecked Sendable {
    private let members: [String: SwarmMember]
    private let entryPoint: String
    private let hookRegistry: HookRegistry
    public let maxHandoffs: Int

    /// Shared context accessible to all agents in the swarm.
    public let sharedContext: AgentState = AgentState()

    public init(
        members: [SwarmMember],
        entryPoint: String? = nil,
        hookRegistry: HookRegistry = HookRegistry(),
        maxHandoffs: Int = 20
    ) {
        var memberMap: [String: SwarmMember] = [:]
        for member in members { memberMap[member.id] = member }
        self.members = memberMap
        self.entryPoint = entryPoint ?? members.first?.id ?? ""
        self.hookRegistry = hookRegistry
        self.maxHandoffs = maxHandoffs
    }

    /// Execute the swarm with the given input.
    public func run(_ input: String) async throws -> MultiAgentResult {
        var nodeResults: [String: AgentResult] = [:]
        var executionOrder: [String] = []
        var totalUsage = Usage()
        var currentNodeId = entryPoint
        var handoffCount = 0
        var currentInput = input
        var handoffMessage: String?

        while handoffCount <= maxHandoffs {
            guard let member = members[currentNodeId] else {
                throw StrandsError.routingFailed(reason: "Swarm member '\(currentNodeId)' not found")
            }

            // Inject handoff tool
            let handoffState = HandoffState()
            let handoffTool = makeHandoffTool(
                currentMember: currentNodeId,
                allMembers: members,
                state: handoffState
            )
            member.agent.toolRegistry.register(handoffTool)
            defer { member.agent.toolRegistry.unregister(name: handoffTool.name) }

            // Build rich input for the agent
            let richInput = buildRichInput(
                originalTask: input,
                currentInput: currentInput,
                handoffMessage: handoffMessage,
                executionOrder: executionOrder,
                members: members
            )

            // Execute agent
            let result = try await member.agent.run(richInput)

            nodeResults[currentNodeId] = result
            executionOrder.append(currentNodeId)
            totalUsage.inputTokens += result.usage.inputTokens
            totalUsage.outputTokens += result.usage.outputTokens
            totalUsage.totalTokens += result.usage.totalTokens

            // Check for handoff
            if let nextNode = handoffState.handoffTarget {
                try await hookRegistry.invoke(MultiAgentHandoffEvent(
                    fromNode: currentNodeId,
                    toNode: nextNode,
                    message: handoffState.handoffMessage
                ))

                handoffMessage = handoffState.handoffMessage
                currentInput = result.message.textContent
                currentNodeId = nextNode
                handoffCount += 1

                // Reset the next agent's conversation
                members[nextNode]?.agent.resetConversation()
            } else {
                // No handoff -- swarm is complete
                break
            }
        }

        return MultiAgentResult(
            nodeResults: nodeResults,
            executionOrder: executionOrder,
            totalUsage: totalUsage,
            finalResult: executionOrder.last.flatMap { nodeResults[$0] }
        )
    }

    // MARK: - Private

    private func makeHandoffTool(
        currentMember: String,
        allMembers: [String: SwarmMember],
        state: HandoffState
    ) -> FunctionTool {
        let otherMembers = allMembers.filter { $0.key != currentMember }
        let memberList = otherMembers.map { "\($0.key): \($0.value.description)" }.joined(separator: ", ")

        return FunctionTool(
            name: "handoff_to_agent",
            description: "Hand off the task to another agent. Available agents: \(memberList)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "agent_name": [
                        "type": "string",
                        "description": "The ID of the agent to hand off to",
                        "enum": .array(otherMembers.keys.map { .string($0) }),
                    ],
                    "message": [
                        "type": "string",
                        "description": "Coordination message for the next agent explaining what you've done and what they should do",
                    ],
                ],
                "required": ["agent_name", "message"],
            ]
        ) { input, _ -> String in
            let agentName = input["agent_name"]?.foundationValue as? String ?? ""
            let message = input["message"]?.foundationValue as? String ?? ""
            state.handoffTarget = agentName
            state.handoffMessage = message
            return "Handing off to \(agentName)."
        }
    }

    private func buildRichInput(
        originalTask: String,
        currentInput: String,
        handoffMessage: String?,
        executionOrder: [String],
        members: [String: SwarmMember]
    ) -> String {
        var parts: [String] = []

        if let msg = handoffMessage {
            parts.append("Handoff message from previous agent: \(msg)")
        }

        parts.append("User request: \(originalTask)")

        if !executionOrder.isEmpty {
            parts.append("Previous agents: \(executionOrder.joined(separator: " -> "))")
        }

        return parts.joined(separator: "\n\n")
    }
}

// MARK: - HandoffState

private final class HandoffState: @unchecked Sendable {
    var handoffTarget: String?
    var handoffMessage: String?
}
