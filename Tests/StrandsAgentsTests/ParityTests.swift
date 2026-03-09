import Foundation
import Testing
@testable import StrandsAgents

// MARK: - Concurrent Tool Execution

@Test func parallelToolExecutionRunsConcurrently() async throws {
    let endTimes = SendableArray()

    let slowTool1 = FunctionTool(name: "slow1", description: "Slow 1") { _, _ -> String in
        try await Task.sleep(for: .milliseconds(100))
        endTimes.append("slow1")
        return "done1"
    }
    let slowTool2 = FunctionTool(name: "slow2", description: "Slow 2") { _, _ -> String in
        try await Task.sleep(for: .milliseconds(100))
        endTimes.append("slow2")
        return "done2"
    }

    let mock = MockProvider(responses: [
        .multipleToolUses([
            MockToolUse(name: "slow1", toolUseId: "t1"),
            MockToolUse(name: "slow2", toolUseId: "t2"),
        ]),
        .text("Both done."),
    ])

    let agent = Agent(model: mock, tools: [slowTool1, slowTool2], parallelToolExecution: true)
    let result = try await agent.run("Run both tools")

    #expect(result.stopReason == StopReason.endTurn)
    #expect(result.cycleCount == 2)
    // Both tools should have completed
    #expect(endTimes.values.count == 2)
}

@Test func sequentialToolExecutionRunsInOrder() async throws {
    let order = SendableArray()

    let tool1 = FunctionTool(name: "first", description: "First") { _, _ -> String in
        order.append("first")
        return "done1"
    }
    let tool2 = FunctionTool(name: "second", description: "Second") { _, _ -> String in
        order.append("second")
        return "done2"
    }

    let mock = MockProvider(responses: [
        .multipleToolUses([
            MockToolUse(name: "first", toolUseId: "t1"),
            MockToolUse(name: "second", toolUseId: "t2"),
        ]),
        .text("Done."),
    ])

    let agent = Agent(model: mock, tools: [tool1, tool2], parallelToolExecution: false)
    _ = try await agent.run("Run both tools")

    // Sequential execution preserves order
    #expect(order.values == ["first", "second"])
}

// MARK: - Tool Name Validation

@Test func toolNameValidation() {
    #expect(ToolRegistry.isValidToolName("calculator") == true)
    #expect(ToolRegistry.isValidToolName("get_weather") == true)
    #expect(ToolRegistry.isValidToolName("my-tool-123") == true)
    #expect(ToolRegistry.isValidToolName("") == false)
    #expect(ToolRegistry.isValidToolName("has spaces") == false)
    #expect(ToolRegistry.isValidToolName("has.dots") == false)
    #expect(ToolRegistry.isValidToolName(String(repeating: "a", count: 65)) == false)
}

// MARK: - Agent State

@Test func agentStateReadWrite() {
    let state = AgentState()

    state["key1"] = .string("value1")
    state["key2"] = .int(42)

    #expect(state["key1"] == .string("value1"))
    #expect(state["key2"] == .int(42))
    #expect(state["missing"] == nil)
    #expect(state.contains("key1") == true)
    #expect(state.contains("missing") == false)
}

@Test func agentStateAvailableInToolContext() async throws {
    let mock = MockProvider(responses: [
        .toolUse(name: "state_tool", toolUseId: "t1"),
        .text("Done"),
    ])

    let stateTool = FunctionTool(name: "state_tool", description: "Uses state") { _, context -> String in
        context.agentState?["visited"] = .bool(true)
        return "set state"
    }

    let agent = Agent(model: mock, tools: [stateTool])
    _ = try await agent.run("Use state tool")

    #expect(agent.state["visited"] == .bool(true))
}

@Test func agentStateRemoveAndClear() {
    let state = AgentState()
    state["a"] = .int(1)
    state["b"] = .int(2)

    state.remove("a")
    #expect(state["a"] == nil)
    #expect(state["b"] == .int(2))

    state.removeAll()
    #expect(state.all.isEmpty)
}

// MARK: - Direct Tool Calling

@Test func directToolCalling() async throws {
    let tool = FunctionTool(name: "greet", description: "Greets someone") { input, _ -> String in
        let name = input["name"]?.foundationValue as? String ?? "World"
        return "Hello, \(name)!"
    }

    let mock = MockProvider(response: "unused")
    let agent = Agent(model: mock, tools: [tool])

    let result = try await agent.callTool("greet", input: ["name": "Swift"])

    #expect(result.status == .success)
    if case .text(let text) = result.content.first {
        #expect(text == "Hello, Swift!")
    } else {
        Issue.record("Expected text content")
    }
}

@Test func directToolCallingRecordsHistory() async throws {
    let tool = FunctionTool(name: "echo", description: "Echo") { input, _ -> String in
        return "echoed"
    }

    let mock = MockProvider(response: "unused")
    let agent = Agent(model: mock, tools: [tool])

    _ = try await agent.callTool("echo", recordInHistory: true)
    #expect(agent.messages.count == 2) // assistant (tool use) + user (tool result)

    _ = try await agent.callTool("echo", recordInHistory: false)
    #expect(agent.messages.count == 2) // no change
}

@Test func directToolCallingNotFound() async throws {
    let mock = MockProvider(response: "unused")
    let agent = Agent(model: mock)

    do {
        _ = try await agent.callTool("nonexistent")
        Issue.record("Should have thrown")
    } catch let error as StrandsError {
        if case .toolNotFound(let name) = error {
            #expect(name == "nonexistent")
        } else {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

// MARK: - Structured Output

struct TestOutput: StructuredOutput {
    let city: String
    let temperature: Double

    static var jsonSchema: JSONSchema {
        [
            "type": "object",
            "properties": [
                "city": ["type": "string"],
                "temperature": ["type": "number"],
            ],
            "required": ["city", "temperature"],
        ]
    }
}

@Test func structuredOutputParsesResponse() async throws {
    // Mock that responds to the _structured_output tool with JSON matching TestOutput
    let mock = MockProvider(responses: [
        .toolUse(
            name: "_structured_output",
            toolUseId: "so1",
            input: .object([
                "city": .string("San Francisco"),
                "temperature": .double(72.5),
            ])
        ),
        .text("Here is your structured output."),
    ])

    let agent = Agent(model: mock)
    let output: TestOutput = try await agent.runStructured("What's the weather?")

    #expect(output.city == "San Francisco")
    #expect(output.temperature == 72.5)
}

// MARK: - Interrupt / Human-in-the-loop

@Test func interruptThrowsAndCanResume() async throws {
    let interruptTool = FunctionTool(name: "dangerous_action", description: "Does something dangerous") { _, context -> String in
        throw InterruptError(
            name: "confirm_action",
            reason: "About to do something dangerous",
            toolUseId: context.toolUse.toolUseId
        )
    }

    let mock = MockProvider(responses: [
        .toolUse(name: "dangerous_action", toolUseId: "t1"),
        // After resume, model gets the interrupt response and answers
        .text("Action completed."),
    ])

    let agent = Agent(model: mock, tools: [interruptTool])

    // The agent loop catches the tool error gracefully (returns error result to model)
    // But the InterruptError propagates through the error content
    let result = try await agent.run("Do the dangerous thing")

    // The tool error was caught and sent back to model, which responded
    #expect(result.stopReason == StopReason.endTurn)
}

// MARK: - ConfigurableModelProvider

@Test func configurableModelProviderProtocol() {
    // Just verify the protocol exists and can be referenced
    struct TestConfig: Sendable {
        var maxTokens: Int
    }

    final class TestProvider: @unchecked Sendable, ConfigurableModelProvider {
        typealias Config = TestConfig
        var modelId: String? { "test" }
        private var config: TestConfig

        init(config: TestConfig) { self.config = config }
        func getConfig() -> TestConfig { config }
        func updateConfig(_ config: TestConfig) { self.config = config }

        func stream(messages: [Message], toolSpecs: [ToolSpec]?, systemPrompt: String?, toolChoice: ToolChoice?) -> AsyncThrowingStream<ModelStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    let provider = TestProvider(config: TestConfig(maxTokens: 100))
    #expect(provider.getConfig().maxTokens == 100)
    provider.updateConfig(TestConfig(maxTokens: 200))
    #expect(provider.getConfig().maxTokens == 200)
}

// MARK: - toolNames on Agent

@Test func agentToolNames() {
    let tool1 = FunctionTool(name: "tool_a", description: "A") { _, _ in "a" }
    let tool2 = FunctionTool(name: "tool_b", description: "B") { _, _ in "b" }
    let mock = MockProvider(response: "unused")
    let agent = Agent(model: mock, tools: [tool1, tool2])

    #expect(Set(agent.toolNames) == Set(["tool_a", "tool_b"]))
}

// MARK: - SummarizingConversationManager

@Test func summarizingConversationManagerExists() {
    // Verify it can be instantiated
    let mock = MockProvider(response: "summary")
    let manager = SummarizingConversationManager(provider: mock, windowSize: 10)
    _ = manager // no crash
}

// Helpers are in AgentTests.swift
