import Foundation

/// Abstract storage interface for session persistence.
///
/// Implementations provide the actual I/O (file system, S3, database, etc.).
/// The `RepositorySessionManager` uses this to persist agent state.
public protocol SessionRepository: Sendable {
    // MARK: - Session

    /// Create a new session. Throws if it already exists.
    func createSession(sessionId: String, data: SessionData) async throws

    /// Read a session's metadata.
    func readSession(sessionId: String) async throws -> SessionData?

    /// Delete a session and all its data.
    func deleteSession(sessionId: String) async throws

    // MARK: - Agent State

    /// Create or update agent state within a session.
    func updateAgent(sessionId: String, agentId: String, state: AgentSessionState) async throws

    /// Read agent state.
    func readAgent(sessionId: String, agentId: String) async throws -> AgentSessionState?

    // MARK: - Messages

    /// Append a message to the session.
    func createMessage(sessionId: String, agentId: String, index: Int, message: SessionMessage) async throws

    /// Read a specific message by index.
    func readMessage(sessionId: String, agentId: String, index: Int) async throws -> SessionMessage?

    /// Update an existing message (e.g. for redaction).
    func updateMessage(sessionId: String, agentId: String, index: Int, message: SessionMessage) async throws

    /// List messages with optional pagination.
    func listMessages(sessionId: String, agentId: String, offset: Int, limit: Int?) async throws -> [SessionMessage]
}

// MARK: - Session Data Types

/// Top-level session metadata.
public struct SessionData: Codable, Sendable {
    public var sessionId: String
    public var createdAt: Date

    public init(sessionId: String, createdAt: Date = Date()) {
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// Persisted agent state within a session.
public struct AgentSessionState: Codable, Sendable {
    public var agentId: String
    public var state: [String: JSONValue]
    public var conversationManagerState: [String: JSONValue]?
    public var stateVersion: Int
    public var createdAt: Date

    public init(
        agentId: String,
        state: [String: JSONValue] = [:],
        conversationManagerState: [String: JSONValue]? = nil,
        stateVersion: Int = 0,
        createdAt: Date = Date()
    ) {
        self.agentId = agentId
        self.state = state
        self.conversationManagerState = conversationManagerState
        self.stateVersion = stateVersion
        self.createdAt = createdAt
    }
}

/// A persisted message with index and metadata.
public struct SessionMessage: Codable, Sendable {
    public var index: Int
    public var message: Message
    public var createdAt: Date
    public var redactedContent: String?

    public init(index: Int, message: Message, createdAt: Date = Date(), redactedContent: String? = nil) {
        self.index = index
        self.message = message
        self.createdAt = createdAt
        self.redactedContent = redactedContent
    }
}
