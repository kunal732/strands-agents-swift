import Foundation

/// Session manager backed by a `SessionRepository`.
///
/// Provides version-tracked persistence of agent state, per-message storage,
/// conversation manager state, and message redaction. Automatically hooks
/// into the agent lifecycle to persist state changes.
///
/// This is the recommended session manager for production use.
///
/// ```swift
/// let manager = RepositorySessionManager(
///     sessionId: "user-123",
///     repository: FileSessionRepository(directory: URL(fileURLWithPath: "~/.strands/sessions"))
/// )
/// let agent = Agent(model: provider, sessionManager: manager)
/// ```
public final class RepositorySessionManager: @unchecked Sendable, HookProvider {
    public let sessionId: String
    public let agentId: String
    private let repository: any SessionRepository
    private var stateVersion: Int = 0
    private var messageIndex: Int = 0
    private var initialized = false

    public init(
        sessionId: String,
        agentId: String = "default",
        repository: any SessionRepository
    ) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.repository = repository
    }

    // MARK: - HookProvider

    public func registerHooks(with registry: HookRegistry) {
        registry.addCallback(AgentInitializedEvent.self) { [self] _ in
            // No-op: initialization happens via initializeAgent()
        }

        registry.addCallback(MessageAddedEvent.self) { [self] event in
            try await self.appendMessage(event.message)
            try await self.syncAgentState(nil)
        }

        registry.addCallback(AfterInvocationEvent.self) { [self] _ in
            try await self.syncAgentState(nil)
        }
    }

    // MARK: - Initialize

    /// Initialize the session, creating it if new or restoring from existing.
    ///
    /// Call this before the first agent invocation to restore previous state.
    /// Returns the restored messages, or nil if this is a new session.
    public func initializeAgent(agent: Agent) async throws -> [Message]? {
        guard !initialized else { return nil }

        // Try to read existing session
        if let _ = try await repository.readSession(sessionId: sessionId) {
            // Session exists -- restore agent state and messages
            if let agentState = try await repository.readAgent(sessionId: sessionId, agentId: agentId) {
                // Restore agent state
                for (key, value) in agentState.state {
                    agent.state[key] = value
                }
                stateVersion = agentState.stateVersion
            }

            // Restore messages
            let sessionMessages = try await repository.listMessages(
                sessionId: sessionId, agentId: agentId, offset: 0, limit: nil
            )

            messageIndex = sessionMessages.count

            let messages = sessionMessages.map(\.message)
            let fixed = fixBrokenToolUse(messages)

            initialized = true
            return fixed
        }

        // New session
        try await repository.createSession(
            sessionId: sessionId,
            data: SessionData(sessionId: sessionId)
        )

        try await repository.updateAgent(
            sessionId: sessionId,
            agentId: agentId,
            state: AgentSessionState(agentId: agentId)
        )

        initialized = true
        return nil
    }

    // MARK: - Message Persistence

    /// Persist a new message.
    public func appendMessage(_ message: Message) async throws {
        let sessionMessage = SessionMessage(
            index: messageIndex,
            message: message
        )
        try await repository.createMessage(
            sessionId: sessionId, agentId: agentId,
            index: messageIndex, message: sessionMessage
        )
        messageIndex += 1
    }

    /// Redact the content of the latest message.
    public func redactLatestMessage(replacement: String) async throws {
        guard messageIndex > 0 else { return }
        let lastIndex = messageIndex - 1
        if var msg = try await repository.readMessage(sessionId: sessionId, agentId: agentId, index: lastIndex) {
            msg.redactedContent = replacement
            try await repository.updateMessage(
                sessionId: sessionId, agentId: agentId,
                index: lastIndex, message: msg
            )
        }
    }

    // MARK: - State Sync

    /// Sync agent state to the repository if it has changed.
    public func syncAgentState(_ agent: Agent?) async throws {
        let currentVersion = stateVersion + 1

        let agentState = AgentSessionState(
            agentId: agentId,
            state: agent?.state.all ?? [:],
            stateVersion: currentVersion
        )

        try await repository.updateAgent(
            sessionId: sessionId, agentId: agentId,
            state: agentState
        )
        stateVersion = currentVersion
    }

    // MARK: - Private

    /// Fix orphaned tool use/result pairs from interrupted sessions.
    private func fixBrokenToolUse(_ restored: [Message]) -> [Message] {
        var messages = restored

        // If last message is an assistant with tool uses but no following tool results,
        // remove the orphaned tool use message
        if let last = messages.last, last.role == .assistant && !last.toolUses.isEmpty {
            messages.removeLast()
        }

        // If first message is a user with tool results but no preceding tool use,
        // remove the orphaned tool result message
        if let first = messages.first, first.role == .user && !first.toolResults.isEmpty {
            messages.removeFirst()
        }

        return messages
    }
}

// MARK: - Legacy Compatibility

/// The original simple SessionManager, kept for backward compatibility.
/// For production use, prefer `RepositorySessionManager`.
extension SessionManager {
    /// Create a RepositorySessionManager from a SessionStorage.
    public static func repository(
        sessionId: String,
        agentId: String = "default",
        repository: any SessionRepository
    ) -> RepositorySessionManager {
        RepositorySessionManager(sessionId: sessionId, agentId: agentId, repository: repository)
    }
}
