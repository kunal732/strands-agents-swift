import Foundation
import Testing
@testable import StrandsAgents

// MARK: - FileSessionRepository Tests

@Test func fileSessionRepositoryCreateAndRead() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let repo = FileSessionRepository(directory: tmpDir)

    // Create session
    try await repo.createSession(sessionId: "test1", data: SessionData(sessionId: "test1"))

    // Read session
    let session = try await repo.readSession(sessionId: "test1")
    #expect(session?.sessionId == "test1")
}

@Test func fileSessionRepositoryMessagePersistence() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let repo = FileSessionRepository(directory: tmpDir)
    try await repo.createSession(sessionId: "s1", data: SessionData(sessionId: "s1"))

    // Create messages
    let msg0 = SessionMessage(index: 0, message: .user("Hello"))
    let msg1 = SessionMessage(index: 1, message: .assistant("Hi there"))
    let msg2 = SessionMessage(index: 2, message: .user("How are you?"))

    try await repo.createMessage(sessionId: "s1", agentId: "a1", index: 0, message: msg0)
    try await repo.createMessage(sessionId: "s1", agentId: "a1", index: 1, message: msg1)
    try await repo.createMessage(sessionId: "s1", agentId: "a1", index: 2, message: msg2)

    // List all messages
    let all = try await repo.listMessages(sessionId: "s1", agentId: "a1", offset: 0, limit: nil)
    #expect(all.count == 3)
    #expect(all[0].message.textContent == "Hello")
    #expect(all[2].message.textContent == "How are you?")

    // Paginate
    let page = try await repo.listMessages(sessionId: "s1", agentId: "a1", offset: 1, limit: 1)
    #expect(page.count == 1)
    #expect(page[0].message.textContent == "Hi there")
}

@Test func fileSessionRepositoryAgentState() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let repo = FileSessionRepository(directory: tmpDir)
    try await repo.createSession(sessionId: "s1", data: SessionData(sessionId: "s1"))

    let state = AgentSessionState(
        agentId: "a1",
        state: ["preference": .string("dark_mode")],
        stateVersion: 1
    )
    try await repo.updateAgent(sessionId: "s1", agentId: "a1", state: state)

    let restored = try await repo.readAgent(sessionId: "s1", agentId: "a1")
    #expect(restored?.state["preference"] == .string("dark_mode"))
    #expect(restored?.stateVersion == 1)
}

@Test func fileSessionRepositoryMessageRedaction() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let repo = FileSessionRepository(directory: tmpDir)
    try await repo.createSession(sessionId: "s1", data: SessionData(sessionId: "s1"))

    let msg = SessionMessage(index: 0, message: .user("My SSN is 123-45-6789"))
    try await repo.createMessage(sessionId: "s1", agentId: "a1", index: 0, message: msg)

    // Redact
    var updated = msg
    updated.redactedContent = "My SSN is [REDACTED]"
    try await repo.updateMessage(sessionId: "s1", agentId: "a1", index: 0, message: updated)

    let restored = try await repo.readMessage(sessionId: "s1", agentId: "a1", index: 0)
    #expect(restored?.redactedContent == "My SSN is [REDACTED]")
}

@Test func fileSessionRepositoryDeleteSession() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let repo = FileSessionRepository(directory: tmpDir)
    try await repo.createSession(sessionId: "s1", data: SessionData(sessionId: "s1"))

    let exists = try await repo.readSession(sessionId: "s1")
    #expect(exists != nil)

    try await repo.deleteSession(sessionId: "s1")

    let gone = try await repo.readSession(sessionId: "s1")
    #expect(gone == nil)
}

// MARK: - RepositorySessionManager Tests

@Test func repositorySessionManagerInitAndRestore() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let repo = FileSessionRepository(directory: tmpDir)
    let mock = MockProvider(responses: [.text("First response"), .text("Second response")])

    // First agent -- create session and save messages
    let manager1 = RepositorySessionManager(sessionId: "s1", repository: repo)
    let agent1 = Agent(model: mock)
    let restored1 = try await manager1.initializeAgent(agent: agent1)
    #expect(restored1 == nil) // New session

    try await manager1.appendMessage(.user("Hello"))
    try await manager1.appendMessage(.assistant("Hi there"))

    // Second agent -- restore from same session
    let manager2 = RepositorySessionManager(sessionId: "s1", repository: repo)
    let agent2 = Agent(model: mock)
    let restored2 = try await manager2.initializeAgent(agent: agent2)
    #expect(restored2 != nil)
    #expect(restored2?.count == 2)
    #expect(restored2?[0].textContent == "Hello")
    #expect(restored2?[1].textContent == "Hi there")
}

@Test func repositorySessionManagerFixesBrokenToolUse() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let repo = FileSessionRepository(directory: tmpDir)
    let mock = MockProvider(response: "test")

    // Save a session with orphaned tool use (no following tool result)
    let manager1 = RepositorySessionManager(sessionId: "s1", repository: repo)
    let agent1 = Agent(model: mock)
    _ = try await manager1.initializeAgent(agent: agent1)

    try await manager1.appendMessage(.user("Use tool"))
    try await manager1.appendMessage(Message(role: .assistant, content: [
        .toolUse(ToolUseBlock(toolUseId: "t1", name: "test", input: .object([:])))
    ]))
    // No tool result message -- simulates interrupted session

    // Restore -- should fix by removing orphaned tool use
    let manager2 = RepositorySessionManager(sessionId: "s1", repository: repo)
    let agent2 = Agent(model: mock)
    let restored = try await manager2.initializeAgent(agent: agent2)
    #expect(restored?.count == 1) // Only the user message remains
    #expect(restored?[0].textContent == "Use tool")
}
