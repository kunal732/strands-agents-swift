import Foundation

/// Manages persistence and restoration of agent session state.
///
/// Hooks into agent lifecycle events to automatically save and restore
/// conversation history and agent state.
public final class SessionManager: @unchecked Sendable, HookProvider {
    public let storage: any SessionStorage
    public let sessionId: String

    public init(storage: any SessionStorage, sessionId: String = UUID().uuidString) {
        self.storage = storage
        self.sessionId = sessionId
    }

    // MARK: - HookProvider

    public func registerHooks(with registry: HookRegistry) {
        registry.addCallback(AfterInvocationEvent.self) { [self] event in
            try await self.save(result: event.result)
        }
    }

    // MARK: - Save / Restore

    /// Persist the current agent state.
    public func save(messages: [Message]) async throws {
        let snapshot = SessionSnapshot(
            sessionId: sessionId,
            messages: messages,
            timestamp: Date()
        )
        let data = try JSONEncoder().encode(snapshot)
        try await storage.save(sessionId: sessionId, data: data)
    }

    private func save(result: AgentResult) async throws {
        // We only have the result here; the agent's full message array
        // is saved by the Agent after invocation.
    }

    /// Restore messages from a previous session.
    public func restore() async throws -> [Message]? {
        guard let data = try await storage.load(sessionId: sessionId) else { return nil }
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        return snapshot.messages
    }
}

// MARK: - Snapshot

struct SessionSnapshot: Codable {
    var sessionId: String
    var messages: [Message]
    var timestamp: Date
}
