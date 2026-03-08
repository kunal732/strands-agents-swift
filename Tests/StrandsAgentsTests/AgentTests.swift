import Foundation
import Testing
@testable import StrandsAgents

// MARK: - Basic Agent Tests

@Test func agentSimpleTextResponse() async throws {
    let mock = MockProvider(response: "Hello, world!")
    let agent = Agent(model: mock)

    let result = try await agent.run("Hi")

    #expect(result.stopReason == .endTurn)
    #expect(result.message.textContent == "Hello, world!")
    #expect(result.cycleCount == 1)
    #expect(result.usage.totalTokens == 30)
}

@Test func agentPreservesConversationHistory() async throws {
    let mock = MockProvider(responses: [
        .text("First response"),
        .text("Second response"),
    ])
    let agent = Agent(model: mock)

    _ = try await agent.run("First message")
    #expect(agent.messages.count == 2) // user + assistant

    _ = try await agent.run("Second message")
    #expect(agent.messages.count == 4) // 2 user + 2 assistant
}

@Test func agentResetConversation() async throws {
    let mock = MockProvider(response: "Hello")
    let agent = Agent(model: mock)

    _ = try await agent.run("Hi")
    #expect(agent.messages.count == 2)

    agent.resetConversation()
    #expect(agent.messages.isEmpty)
}

@Test func agentResultDescription() async throws {
    let mock = MockProvider(response: "The answer is 42")
    let agent = Agent(model: mock)
    let result = try await agent.run("Question")
    #expect(result.description == "The answer is 42")
}

// MARK: - Tool Calling Tests

@Test func agentCallsTool() async throws {
    let toolUseId = "test-tool-use-1"
    let mock = MockProvider(responses: [
        .toolUse(name: "calculator", toolUseId: toolUseId, input: ["expression": "2+2"]),
        .text("The answer is 4."),
    ])

    let calculator = FunctionTool(
        name: "calculator",
        description: "Evaluate math",
        inputSchema: [
            "type": "object",
            "properties": ["expression": ["type": "string"]],
        ]
    ) { input, _ in
        return "4"
    }

    let agent = Agent(model: mock, tools: [calculator])
    let result = try await agent.run("What is 2+2?")

    #expect(result.stopReason == .endTurn)
    #expect(result.message.textContent == "The answer is 4.")
    #expect(result.cycleCount == 2) // one cycle for tool call, one for response
}

@Test func agentHandlesToolNotFound() async throws {
    let mock = MockProvider(responses: [
        .toolUse(name: "nonexistent_tool", toolUseId: "t1"),
        .text("Sorry, tool failed."),
    ])

    let agent = Agent(model: mock)
    let result = try await agent.run("Use a tool")

    // Agent should continue even if tool is not found (error result sent back to model)
    #expect(result.stopReason == .endTurn)
    #expect(result.cycleCount == 2)
}

@Test func agentHandlesToolError() async throws {
    let mock = MockProvider(responses: [
        .toolUse(name: "failing_tool", toolUseId: "t1"),
        .text("Tool failed, but I can help."),
    ])

    struct FailingError: Error {}
    let failingTool = FunctionTool(
        name: "failing_tool",
        description: "Always fails"
    ) { _, _ -> String in
        throw FailingError()
    }

    let agent = Agent(model: mock, tools: [failingTool])
    let result = try await agent.run("Do something")

    #expect(result.stopReason == .endTurn)
    #expect(result.message.textContent == "Tool failed, but I can help.")
}

// MARK: - Streaming Tests

@Test func agentStreamYieldsTextDeltas() async throws {
    let mock = MockProvider(response: "Hello streaming world")
    let agent = Agent(model: mock)

    var textDeltas: [String] = []
    var gotResult = false

    for try await event in agent.stream("Hi") {
        switch event {
        case .textDelta(let text):
            textDeltas.append(text)
        case .result:
            gotResult = true
        default:
            break
        }
    }

    #expect(!textDeltas.isEmpty)
    #expect(textDeltas.joined() == "Hello streaming world")
    #expect(gotResult)
}

@Test func agentStreamYieldsToolResults() async throws {
    let mock = MockProvider(responses: [
        .toolUse(name: "test_tool", toolUseId: "t1", input: .object([:])),
        .text("Done."),
    ])

    let tool = FunctionTool(name: "test_tool", description: "test") { _, _ in "ok" }
    let agent = Agent(model: mock, tools: [tool])

    var toolResults: [ToolResultBlock] = []
    for try await event in agent.stream("Go") {
        if case .toolResult(let result) = event {
            toolResults.append(result)
        }
    }

    #expect(toolResults.count == 1)
    #expect(toolResults[0].status == .success)
}

// MARK: - Hook Tests

@Test func hooksFireInOrder() async throws {
    let mock = MockProvider(response: "Hello")
    let events = SendableArray()

    let agent = Agent(model: mock)

    agent.hookRegistry.addCallback(BeforeInvocationEvent.self) { _ in
        events.append("before_invocation")
    }
    agent.hookRegistry.addCallback(BeforeModelCallEvent.self) { _ in
        events.append("before_model")
    }
    agent.hookRegistry.addCallback(AfterModelCallEvent.self) { _ in
        events.append("after_model")
    }
    agent.hookRegistry.addCallback(AfterInvocationEvent.self) { _ in
        events.append("after_invocation")
    }

    _ = try await agent.run("Hi")

    let recorded = events.values
    #expect(recorded == ["before_invocation", "before_model", "after_model", "after_invocation"])
}

@Test func toolHooksFire() async throws {
    let mock = MockProvider(responses: [
        .toolUse(name: "my_tool", toolUseId: "t1"),
        .text("Done"),
    ])
    let tool = FunctionTool(name: "my_tool", description: "test") { _, _ in "result" }
    let agent = Agent(model: mock, tools: [tool])

    let events = SendableArray()
    agent.hookRegistry.addCallback(BeforeToolCallEvent.self) { event in
        events.append("before_tool:\(event.toolUse.name)")
    }
    agent.hookRegistry.addCallback(AfterToolCallEvent.self) { event in
        events.append("after_tool:\(event.result.status)")
    }

    _ = try await agent.run("Call tool")

    let recorded = events.values
    #expect(recorded.contains("before_tool:my_tool"))
    #expect(recorded.contains("after_tool:success"))
}

// MARK: - Conversation Manager Tests

@Test func conversationManagerAppliedDuringToolLoop() async throws {
    // Use a conversation manager with a very small window
    let mock = MockProvider(responses: [
        .toolUse(name: "t", toolUseId: "t1"),
        .toolUse(name: "t", toolUseId: "t2"),
        .toolUse(name: "t", toolUseId: "t3"),
        .text("Done"),
    ])
    let tool = FunctionTool(name: "t", description: "test") { _, _ in "ok" }
    let manager = SlidingWindowConversationManager(windowSize: 6)
    let agent = Agent(model: mock, tools: [tool], conversationManager: manager)

    let result = try await agent.run("Go")
    #expect(result.stopReason == .endTurn)
    // Messages should have been trimmed
    #expect(agent.messages.count <= 7) // windowSize + some
}

// MARK: - Max Cycles Test

@Test func agentRespectsMaxCycles() async throws {
    // Create a mock that always requests tool use (infinite loop)
    let responses: [MockResponse] = (0..<25).map { i in
        .toolUse(name: "loop_tool", toolUseId: "t\(i)")
    }
    let mock = MockProvider(responses: responses)
    let tool = FunctionTool(name: "loop_tool", description: "test") { _, _ in "ok" }
    let agent = Agent(model: mock, tools: [tool], maxCycles: 3)

    let result = try await agent.run("Loop forever")
    #expect(result.cycleCount == 3)
}

// MARK: - System Prompt Tests

@Test func systemPromptPassedToProvider() async throws {
    let mock = MockProvider(response: "I am helpful")
    let agent = Agent(model: mock, systemPrompt: "You are a helpful assistant")

    _ = try await agent.run("Hi")

    // MockProvider records received messages
    #expect(mock.receivedMessages.count == 1)
}

// MARK: - Agent Input Tests

@Test func agentAcceptsContentBlocks() async throws {
    let mock = MockProvider(response: "I see the image")
    let agent = Agent(model: mock)

    let result = try await agent.run(.contentBlocks([
        .text(TextBlock(text: "What's in this image?")),
        .image(ImageBlock(format: .png, source: .base64(mediaType: "image/png", data: "..."))),
    ]))

    #expect(result.message.textContent == "I see the image")
    #expect(agent.messages[0].content.count == 2)
}

// MARK: - MockProvider Tests

@Test func mockProviderExhaustsResponses() async throws {
    let mock = MockProvider(responses: [.text("Only one")])
    let agent = Agent(model: mock)

    _ = try await agent.run("First")
    let result = try await agent.run("Second")

    // Should get fallback message
    #expect(result.message.textContent.contains("no more responses"))
}

@Test func mockProviderReset() async throws {
    let mock = MockProvider(response: "Hello")
    let agent = Agent(model: mock)

    _ = try await agent.run("Hi")
    #expect(mock.receivedMessages.count == 1)

    mock.reset()
    #expect(mock.receivedMessages.isEmpty)
}

// MARK: - Helpers

final class SendableArray: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    var values: [String] {
        lock.withLock { _values }
    }

    func append(_ value: String) {
        lock.withLock { _values.append(value) }
    }
}
