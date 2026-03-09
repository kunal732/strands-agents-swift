import Foundation
import Testing
@testable import StrandsAgents

// MARK: - Graph Orchestrator

@Test func graphSequentialExecution() async throws {
    let mock1 = MockProvider(response: "Research: quantum computing is fascinating")
    let mock2 = MockProvider(response: "Article: Quantum computing explained simply")

    let researcher = Agent(model: mock1, systemPrompt: "You are a researcher")
    let writer = Agent(model: mock2, systemPrompt: "You are a writer")

    let graph = GraphOrchestrator(nodes: [
        GraphNode(id: "research", agent: researcher),
        GraphNode(id: "write", agent: writer, dependencies: ["research"]),
    ])

    let result = try await graph.run("Write about quantum computing")

    #expect(result.executionOrder == ["research", "write"])
    #expect(result.nodeResults.count == 2)
    #expect(result.finalResult?.message.textContent == "Article: Quantum computing explained simply")
}

@Test func graphParallelExecution() async throws {
    let mock1 = MockProvider(response: "Topic A analysis")
    let mock2 = MockProvider(response: "Topic B analysis")
    let mock3 = MockProvider(response: "Combined summary")

    let agent1 = Agent(model: mock1)
    let agent2 = Agent(model: mock2)
    let summarizer = Agent(model: mock3)

    let graph = GraphOrchestrator(nodes: [
        GraphNode(id: "analyze_a", agent: agent1),
        GraphNode(id: "analyze_b", agent: agent2),
        GraphNode(id: "summarize", agent: summarizer, dependencies: ["analyze_a", "analyze_b"]),
    ])

    let result = try await graph.run("Analyze both topics")

    #expect(result.nodeResults.count == 3)
    // analyze_a and analyze_b should both be before summarize
    let sumIndex = result.executionOrder.firstIndex(of: "summarize")!
    let aIndex = result.executionOrder.firstIndex(of: "analyze_a")!
    let bIndex = result.executionOrder.firstIndex(of: "analyze_b")!
    #expect(aIndex < sumIndex)
    #expect(bIndex < sumIndex)
}

// MARK: - Swarm Orchestrator

@Test func swarmBasicHandoff() async throws {
    // Researcher calls handoff_to_agent tool to hand off to writer
    let researcherMock = MockProvider(responses: [
        .toolUse(
            name: "handoff_to_agent",
            toolUseId: "h1",
            input: .object([
                "agent_name": .string("writer"),
                "message": .string("Research complete. Please write the article."),
            ])
        ),
        .text("Handing off."),
    ])
    let writerMock = MockProvider(response: "Here is the final article about quantum computing.")

    let researcher = SwarmMember(
        id: "researcher",
        description: "Researches topics",
        agent: Agent(model: researcherMock)
    )
    let writer = SwarmMember(
        id: "writer",
        description: "Writes articles",
        agent: Agent(model: writerMock)
    )

    let swarm = SwarmOrchestrator(
        members: [researcher, writer],
        entryPoint: "researcher"
    )

    let result = try await swarm.run("Write about quantum computing")

    #expect(result.executionOrder.contains("researcher"))
    #expect(result.executionOrder.contains("writer"))
    #expect(result.finalResult?.message.textContent == "Here is the final article about quantum computing.")
}

@Test func swarmNoHandoffCompletes() async throws {
    let mock = MockProvider(response: "I can handle this myself. Done.")

    let solo = SwarmMember(
        id: "solo",
        description: "Does everything",
        agent: Agent(model: mock)
    )

    let swarm = SwarmOrchestrator(members: [solo], entryPoint: "solo")
    let result = try await swarm.run("Simple task")

    #expect(result.executionOrder == ["solo"])
    #expect(result.finalResult?.message.textContent == "I can handle this myself. Done.")
}

// MARK: - ToolProvider

@Test func staticToolProviderLoadsTools() async throws {
    let tool1 = FunctionTool(name: "t1", description: "Tool 1") { _, _ in "r1" }
    let tool2 = FunctionTool(name: "t2", description: "Tool 2") { _, _ in "r2" }

    let provider = StaticToolProvider(tools: [tool1, tool2])
    let registry = ToolRegistry()
    try await registry.loadFrom(provider)

    #expect(registry.count == 2)
    #expect(registry.tool(named: "t1") != nil)
    #expect(registry.tool(named: "t2") != nil)
}

// MARK: - MultiAgentResult

@Test func multiAgentResultDescription() {
    let result = MultiAgentResult(
        finalResult: AgentResult(
            stopReason: .endTurn,
            message: .assistant("Final answer")
        )
    )
    #expect(result.description == "Final answer")
}
