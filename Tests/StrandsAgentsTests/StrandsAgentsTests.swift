import Foundation
import Testing
@testable import StrandsAgents

@Test func jsonValueRoundTrips() throws {
    let value: JSONValue = [
        "name": "test",
        "count": 42,
        "enabled": true,
        "tags": ["a", "b"],
        "nested": ["x": 1.5],
    ]

    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    #expect(decoded == value)
}

@Test func messageTextContent() {
    let msg = Message.user("Hello world")
    #expect(msg.textContent == "Hello world")
    #expect(msg.role == .user)
}

@Test func toolRegistryLookup() {
    let tool = FunctionTool(
        name: "test_tool",
        description: "A test tool"
    ) { _, _ in
        return "result"
    }

    let registry = ToolRegistry(tools: [tool])
    #expect(registry.count == 1)
    #expect(registry.tool(named: "test_tool") != nil)
    #expect(registry.tool(named: "nonexistent") == nil)
    #expect(registry.toolSpecs.count == 1)
    #expect(registry.toolSpecs[0].name == "test_tool")
}

@Test func slidingWindowTrims() async {
    var messages: [Message] = (0..<50).map { i in
        Message.user("Message \(i)")
    }

    let manager = SlidingWindowConversationManager(windowSize: 40)
    await manager.applyManagement(messages: &messages)

    #expect(messages.count == 40)
}

@Test func stopReasonCodable() throws {
    let reason = StopReason.toolUse
    let data = try JSONEncoder().encode(reason)
    let decoded = try JSONDecoder().decode(StopReason.self, from: data)
    #expect(decoded == .toolUse)
}

@Test func contentBlockTextExtraction() {
    let block = ContentBlock.text(TextBlock(text: "hello"))
    #expect(block.text == "hello")
    #expect(block.toolUse == nil)
}

@Test func agentInputStringLiteral() {
    let input: AgentInput = "Hello"
    if case .text(let text) = input {
        #expect(text == "Hello")
    } else {
        Issue.record("Expected .text case")
    }
}

@Test func retryStrategyPassesThrough() async throws {
    let strategy = RetryStrategy(maxAttempts: 3)
    let result = try await strategy.execute { 42 }
    #expect(result == 42)
}

@Test func hookRegistryInvokesCallbacks() async throws {
    let registry = HookRegistry()
    let box = SendableBox()

    registry.addCallback(BeforeInvocationEvent.self) { _ in
        box.set(true)
    }

    try await registry.invoke(BeforeInvocationEvent(messages: []))
    #expect(box.value == true)
}

final class SendableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set(_ v: Bool) { lock.withLock { _value = v } }
}

@Test func noOpObservabilityHasZeroOverhead() {
    let engine = NoOpObservabilityEngine()
    let span = engine.startSpan(name: "test", attributes: [:])
    engine.endSpan(span, status: .ok)
    engine.recordEvent(name: "test", attributes: [:], spanContext: nil)
    engine.recordMetric(name: "test", value: 1.0, unit: nil, attributes: [:])
}
