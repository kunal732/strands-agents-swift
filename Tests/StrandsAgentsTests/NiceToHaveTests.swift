import Foundation
import Testing
@testable import StrandsAgents

// MARK: - Message Normalization

@Test func messageNormalizerRemovesBlankTextWithToolUse() {
    let messages = [
        Message(role: .assistant, content: [
            .text(TextBlock(text: "")),
            .toolUse(ToolUseBlock(toolUseId: "t1", name: "calc", input: .object([:]))),
        ]),
    ]

    let normalized = MessageNormalizer.normalize(messages)
    // Blank text should be removed when tool use is present
    #expect(normalized[0].content.count == 1)
    #expect(normalized[0].content[0].toolUse != nil)
}

@Test func messageNormalizerReplacesEmptyTextWithPlaceholder() {
    let messages = [Message(role: .user, content: [.text(TextBlock(text: ""))])]
    let normalized = MessageNormalizer.normalize(messages)
    #expect(normalized[0].content[0].text == "[empty]")
}

@Test func messageNormalizerFixesInvalidToolNames() {
    let messages = [
        Message(role: .assistant, content: [
            .toolUse(ToolUseBlock(toolUseId: "t1", name: "invalid tool.name!", input: .object([:]))),
        ]),
    ]

    let normalized = MessageNormalizer.normalize(messages)
    let toolUse = normalized[0].content[0].toolUse!
    // Should be sanitized to valid pattern
    #expect(ToolRegistry.isValidToolName(toolUse.name))
}

@Test func messageNormalizerPreservesValidMessages() {
    let messages = [
        Message.user("Hello"),
        Message.assistant("Hi there"),
    ]
    let normalized = MessageNormalizer.normalize(messages)
    #expect(normalized[0].textContent == "Hello")
    #expect(normalized[1].textContent == "Hi there")
}

// MARK: - Hook Reverse Invocation

@Test func hookRegistryInvokeReversed() async throws {
    let registry = HookRegistry()
    let order = OrderTracker()

    registry.addCallback(AfterInvocationEvent.self) { _ in
        order.append("first")
    }
    registry.addCallback(AfterInvocationEvent.self) { _ in
        order.append("second")
    }
    registry.addCallback(AfterInvocationEvent.self) { _ in
        order.append("third")
    }

    let event = AfterInvocationEvent(result: AgentResult(
        stopReason: .endTurn, message: .assistant("test")
    ))

    try await registry.invokeReversed(event)
    #expect(order.values == ["third", "second", "first"])
}

@Test func hookRegistryCallbackCount() {
    let registry = HookRegistry()
    #expect(registry.callbackCount(for: BeforeModelCallEvent.self) == 0)

    registry.addCallback(BeforeModelCallEvent.self) { _ in }
    registry.addCallback(BeforeModelCallEvent.self) { _ in }
    #expect(registry.callbackCount(for: BeforeModelCallEvent.self) == 2)
}

// MARK: - Per-Turn Conversation Management

@Test func slidingWindowPerTurnMode() {
    let manager = SlidingWindowConversationManager(windowSize: 10, perTurn: true)
    #expect(manager.perTurn == true)
}

// MARK: - S3 Session Storage

@Test func s3SessionStorageInitializes() {
    let storage = S3SessionStorage(bucket: "test-bucket", prefix: "sessions/", region: "us-east-1")
    _ = storage // No crash
}

// MARK: - File Tool Watcher

@Test func fileToolWatcherInitializes() {
    let watcher = FileToolWatcher(directory: URL(fileURLWithPath: "/tmp"))
    watcher.onChange = { urls in
        // Would handle file changes
    }
    _ = watcher // No crash
}

// MARK: - JSON Schema Tool Provider

@Test func jsonSchemaToolProviderLoadsFromDirectory() async throws {
    // Create a temp directory with a tool JSON file
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let toolJSON: [String: Any] = [
        "name": "test_tool",
        "description": "A test tool",
        "inputSchema": ["type": "object"],
    ]
    let data = try JSONSerialization.data(withJSONObject: toolJSON)
    try data.write(to: tmpDir.appendingPathComponent("test_tool.json"))

    let provider = JSONSchemaToolProvider(directory: tmpDir) { name, input, context in
        return "executed \(name)"
    }

    let tools = try await provider.loadTools()
    #expect(tools.count == 1)
    #expect(tools[0].name == "test_tool")
}

// MARK: - A2A Server

@Test func a2aServerGeneratesAgentCard() {
    let mock = MockProvider(response: "test")
    let tool = FunctionTool(name: "search", description: "Search") { _, _ in "result" }
    let agent = Agent(model: mock, tools: [tool])

    let server = A2AServer(agent: agent, name: "Test Agent", port: 9090)
    let card = server.agentCard()

    #expect(card["name"] as? String == "Test Agent")
    #expect((card["skills"] as? [[String: Any]])?.count == 1)
}

@Test func a2aServerHandlesTask() async throws {
    let mock = MockProvider(response: "Agent response to task")
    let agent = Agent(model: mock)

    let server = A2AServer(agent: agent)
    let result = try await server.handleTask(input: [
        "message": ["parts": [["type": "text", "text": "Hello agent"]]],
    ])

    let artifacts = result["artifacts"] as? [[String: Any]]
    let parts = artifacts?.first?["parts"] as? [[String: Any]]
    let text = parts?.first?["text"] as? String
    #expect(text == "Agent response to task")
}

// MARK: - Cache Config

@Test func cacheConfigTypes() {
    let none: CacheConfig = .none
    let auto: CacheConfig = .auto
    let manual: CacheConfig = .manual(positions: [.afterSystemPrompt, .afterToolDefinitions])

    // Just verify they can be created without crash
    _ = (none, auto, manual)
}

// MARK: - Helpers

final class OrderTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func append(_ v: String) { lock.withLock { _values.append(v) } }
}
