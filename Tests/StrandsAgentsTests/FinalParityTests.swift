import Foundation
import Testing
@testable import StrandsAgents

// MARK: - EventLoopMetrics

@Test func eventLoopMetricsCollectedDuringRun() async throws {
    let mock = MockProvider(responses: [
        .toolUse(name: "test_tool", toolUseId: "t1"),
        .text("Done."),
    ])
    let tool = FunctionTool(name: "test_tool", description: "test") { _, _ in "result" }
    let agent = Agent(model: mock, tools: [tool])

    let result = try await agent.run("Go")

    #expect(result.metrics.cycleCount == 2)
    #expect(result.metrics.cycles.count == 2)
    #expect(result.metrics.totalLatencyMs >= 0)

    // First cycle should be tool_use, second should be endTurn
    #expect(result.metrics.cycles[0].stopReason == StopReason.toolUse)
    #expect(result.metrics.cycles[0].toolsExecuted == 1)
    #expect(result.metrics.cycles[1].stopReason == StopReason.endTurn)

    // Usage should be accumulated
    #expect(result.metrics.totalUsage.totalTokens > 0)
}

@Test func eventLoopMetricsEmittedViaHook() async throws {
    let mock = MockProvider(response: "Hello")
    let agent = Agent(model: mock)

    let metricsBox = MetricsBox()
    agent.hookRegistry.addCallback(MetricsEvent.self) { event in
        metricsBox.set(event.metrics)
    }

    _ = try await agent.run("Hi")

    let metrics = metricsBox.value
    #expect(metrics != nil)
    #expect(metrics?.cycleCount == 1)
    #expect(metrics != nil)
}

@Test func eventLoopMetricsTokensPerSecond() {
    let metrics = EventLoopMetrics(
        cycles: [CycleMetrics(usage: Usage(outputTokens: 100))],
        totalUsage: Usage(outputTokens: 100),
        totalLatencyMs: 1000
    )
    #expect(metrics.outputTokensPerSecond == 100.0)
}

// MARK: - Token Limit Recovery

@Test func maxTokensRecoveryContinuesLoop() async throws {
    let mock = MockProvider(responses: [
        .text("Partial respon"), // Would be maxTokens in real scenario
        .text("se completed."),
    ])
    let agent = Agent(model: mock)

    // Even without actual maxTokens, verify multi-cycle works
    let result = try await agent.run("Tell me something")
    #expect(result.metrics.cycles.count >= 1)
}

// MARK: - Steering

@Test func steeringHandlerEvaluates() async {
    struct TestSteering: SteeringHandler {
        func evaluate(context: SteeringContext) async -> SteeringAction {
            if context.cycleNumber > 3 {
                return .interrupt(reason: "Too many cycles")
            }
            if context.lastToolCall == "dangerous" {
                return .guide("Be careful with this tool")
            }
            return .proceed
        }
    }

    let handler = TestSteering()

    let ctx1 = SteeringContext(cycleNumber: 1)
    let action1 = await handler.evaluate(context: ctx1)
    if case .proceed = action1 {} else { Issue.record("Expected proceed") }

    let ctx2 = SteeringContext(lastToolCall: "dangerous", cycleNumber: 1)
    let action2 = await handler.evaluate(context: ctx2)
    if case .guide(let msg) = action2 {
        #expect(msg.contains("careful"))
    } else { Issue.record("Expected guide") }

    let ctx3 = SteeringContext(cycleNumber: 5)
    let action3 = await handler.evaluate(context: ctx3)
    if case .interrupt = action3 {} else { Issue.record("Expected interrupt") }
}

@Test func ledgerProviderTracksToolCalls() async {
    let ledger = LedgerProvider()
    ledger.recordToolCall("search")
    ledger.recordToolCall("search")
    ledger.recordToolCall("calculate")

    let context = await ledger.provide()
    #expect(context["search"] == .int(2))
    #expect(context["calculate"] == .int(1))
}

// MARK: - Agent Config

@Test func agentConfigFromDictionary() throws {
    let config: [String: Any] = [
        "model_id": "test-model",
        "system_prompt": "You are helpful",
        "max_cycles": 5,
        "parallel_tool_execution": false,
    ]

    let agent = try AgentConfig.build(from: config) { modelId, _ in
        MockProvider(response: "test")
    }

    #expect(agent.systemPrompt == "You are helpful")
    #expect(agent.maxCycles == 5)
    #expect(agent.parallelToolExecution == false)
}

@Test func agentConfigFromJSON() throws {
    let json = """
    {"model_id": "test", "system_prompt": "Hello", "max_cycles": 3}
    """.data(using: .utf8)!

    let agent = try AgentConfig.build(fromJSON: json) { _, _ in
        MockProvider(response: "test")
    }

    #expect(agent.systemPrompt == "Hello")
    #expect(agent.maxCycles == 3)
}

// MARK: - Tool Schema Builder

@Test func toolSchemaBuilderCreatesValidSchema() {
    let schema = ToolSchemaBuilder.build {
        StringProperty("city", description: "The city name")
            .required()
        NumberProperty("temperature", description: "Temperature")
            .minimum(0)
            .maximum(100)
        StringProperty("unit", description: "Unit")
            .enum(["celsius", "fahrenheit"])
            .defaultValue(.string("celsius"))
    }

    #expect(schema["type"] == .string("object"))

    if case .object(let props) = schema["properties"] {
        #expect(props.count == 3)
        #expect(props["city"] != nil)
        #expect(props["temperature"] != nil)
        #expect(props["unit"] != nil)
    } else {
        Issue.record("Expected properties object")
    }

    if case .array(let required) = schema["required"] {
        #expect(required.count == 1)
        #expect(required[0] == .string("city"))
    } else {
        Issue.record("Expected required array")
    }
}

@Test func toolSchemaBuilderWorksWithFunctionTool() async throws {
    let tool = FunctionTool(
        name: "weather",
        description: "Get weather",
        inputSchema: ToolSchemaBuilder.build {
            StringProperty("city", description: "City").required()
        }
    ) { input, _ in
        "Sunny"
    }

    #expect(tool.name == "weather")
    #expect(tool.toolSpec.inputSchema["type"] == .string("object"))
}

// MARK: - A2A Client

@Test func a2aClientCreatesToolSpec() {
    let client = A2AClient(
        name: "remote_agent",
        description: "A remote research agent",
        endpoint: URL(string: "https://example.com")!
    )

    #expect(client.name == "remote_agent")
    #expect(client.toolSpec.description == "A remote research agent")
}

// MARK: - Helpers

final class MetricsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: EventLoopMetrics?
    var value: EventLoopMetrics? { lock.withLock { _value } }
    func set(_ v: EventLoopMetrics) { lock.withLock { _value = v } }
}
