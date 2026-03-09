import Foundation
import Testing
@testable import StrandsAgents

// MARK: - CallbackHandler Tests

@Test func printingCallbackHandlerReceivesTextDeltas() async throws {
    let mock = MockProvider(response: "Hello world")
    let collector = CollectingCallbackHandler()

    let agent = Agent(model: mock, callbackHandler: collector)
    _ = try await agent.run("Hi")

    #expect(!collector.textDeltas.isEmpty)
    let joined = collector.textDeltas.joined()
    #expect(joined == "Hello world")
}

@Test func callbackHandlerReceivesToolResults() async throws {
    let mock = MockProvider(responses: [
        .toolUse(name: "test_tool", toolUseId: "t1"),
        .text("Done"),
    ])
    let tool = FunctionTool(name: "test_tool", description: "Test") { _, _ in "result" }
    let collector = CollectingCallbackHandler()

    let agent = Agent(model: mock, tools: [tool], callbackHandler: collector)
    _ = try await agent.run("Use tool")

    #expect(collector.toolResults.count == 1)
    #expect(collector.results.count == 1)
}

@Test func compositeCallbackHandlerDispatchesToAll() async throws {
    let mock = MockProvider(response: "Test")
    let collector1 = CollectingCallbackHandler()
    let collector2 = CollectingCallbackHandler()
    let composite = CompositeCallbackHandler([collector1, collector2])

    let agent = Agent(model: mock, callbackHandler: composite)
    _ = try await agent.run("Hi")

    #expect(!collector1.textDeltas.isEmpty)
    #expect(!collector2.textDeltas.isEmpty)
    #expect(collector1.textDeltas == collector2.textDeltas)
}

@Test func nullCallbackHandlerDoesNothing() async throws {
    let mock = MockProvider(response: "Test")
    let agent = Agent(model: mock) // Default NullCallbackHandler
    let result = try await agent.run("Hi")
    #expect(result.message.textContent == "Test")
}

// MARK: - Plugin Tests

struct ToolCounterPlugin: AgentPlugin {
    let counter: Counter

    func configure(agent: Agent) {
        agent.hookRegistry.addCallback(AfterToolCallEvent.self) { [counter] _ in
            counter.increment()
        }
    }
}

@Test func pluginConfigureCalledDuringInit() async throws {
    let counter = Counter()
    let mock = MockProvider(responses: [
        .toolUse(name: "my_tool", toolUseId: "t1"),
        .text("Done"),
    ])
    let tool = FunctionTool(name: "my_tool", description: "Test") { _, _ in "ok" }

    let agent = Agent(
        model: mock,
        tools: [tool],
        plugins: [ToolCounterPlugin(counter: counter)]
    )

    _ = try await agent.run("Use tool")
    #expect(counter.value == 1)
}

struct ToolProvidingPlugin: AgentPlugin {
    var tools: [any AgentTool] {
        [FunctionTool(name: "plugin_tool", description: "From plugin") { _, _ in "plugin result" }]
    }

    func configure(agent: Agent) {}
}

@Test func pluginCanProvideTools() async throws {
    let mock = MockProvider(responses: [
        .toolUse(name: "plugin_tool", toolUseId: "t1"),
        .text("Done"),
    ])

    let agent = Agent(
        model: mock,
        plugins: [ToolProvidingPlugin()]
    )

    #expect(agent.toolNames.contains("plugin_tool"))

    let result = try await agent.run("Use plugin tool")
    #expect(result.stopReason == StopReason.endTurn)
}

// MARK: - Helpers

final class CollectingCallbackHandler: CallbackHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _textDeltas: [String] = []
    private var _toolResults: [ToolResultBlock] = []
    private var _results: [AgentResult] = []

    var textDeltas: [String] { lock.withLock { _textDeltas } }
    var toolResults: [ToolResultBlock] { lock.withLock { _toolResults } }
    var results: [AgentResult] { lock.withLock { _results } }

    func onTextDelta(_ text: String) async {
        lock.withLock { _textDeltas.append(text) }
    }
    func onToolResult(_ result: ToolResultBlock) async {
        lock.withLock { _toolResults.append(result) }
    }
    func onResult(_ result: AgentResult) async {
        lock.withLock { _results.append(result) }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
