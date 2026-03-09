import Foundation

/// File system-backed session repository.
///
/// Stores session data as JSON files in a directory structure:
/// ```
/// <baseDir>/
/// └── session_<id>/
///     ├── session.json
///     └── agents/
///         └── agent_<id>/
///             ├── agent.json
///             └── messages/
///                 ├── message_0.json
///                 ├── message_1.json
///                 └── ...
/// ```
///
/// Uses atomic writes (write to .tmp, then rename) to prevent corruption.
public struct FileSessionRepository: SessionRepository {
    private let baseDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) {
        if let dir = directory {
            self.baseDir = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseDir = home.appendingPathComponent(".strands/sessions")
        }
    }

    // MARK: - Session

    public func createSession(sessionId: String, data: SessionData) async throws {
        let dir = sessionDir(sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(encode(data), to: dir.appendingPathComponent("session.json"))
    }

    public func readSession(sessionId: String) async throws -> SessionData? {
        let path = sessionDir(sessionId).appendingPathComponent("session.json")
        return try? decode(SessionData.self, from: path)
    }

    public func deleteSession(sessionId: String) async throws {
        let dir = sessionDir(sessionId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Agent

    public func updateAgent(sessionId: String, agentId: String, state: AgentSessionState) async throws {
        let dir = agentDir(sessionId, agentId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(encode(state), to: dir.appendingPathComponent("agent.json"))
    }

    public func readAgent(sessionId: String, agentId: String) async throws -> AgentSessionState? {
        let path = agentDir(sessionId, agentId).appendingPathComponent("agent.json")
        return try? decode(AgentSessionState.self, from: path)
    }

    // MARK: - Messages

    public func createMessage(sessionId: String, agentId: String, index: Int, message: SessionMessage) async throws {
        let dir = messagesDir(sessionId, agentId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWrite(encode(message), to: dir.appendingPathComponent("message_\(index).json"))
    }

    public func readMessage(sessionId: String, agentId: String, index: Int) async throws -> SessionMessage? {
        let path = messagesDir(sessionId, agentId).appendingPathComponent("message_\(index).json")
        return try? decode(SessionMessage.self, from: path)
    }

    public func updateMessage(sessionId: String, agentId: String, index: Int, message: SessionMessage) async throws {
        let path = messagesDir(sessionId, agentId).appendingPathComponent("message_\(index).json")
        try atomicWrite(encode(message), to: path)
    }

    public func listMessages(sessionId: String, agentId: String, offset: Int, limit: Int?) async throws -> [SessionMessage] {
        let dir = messagesDir(sessionId, agentId)
        let fm = FileManager.default

        guard fm.fileExists(atPath: dir.path) else { return [] }

        let files = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("message_") && $0.hasSuffix(".json") }
            .compactMap { filename -> (Int, String)? in
                let name = filename.replacingOccurrences(of: "message_", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                guard let index = Int(name) else { return nil }
                return (index, filename)
            }
            .sorted { $0.0 < $1.0 }

        // Apply offset and limit
        let sliced: [(Int, String)]
        if let limit {
            sliced = Array(files.dropFirst(offset).prefix(limit))
        } else {
            sliced = Array(files.dropFirst(offset))
        }

        return sliced.compactMap { (_, filename) in
            let path = dir.appendingPathComponent(filename)
            return try? decode(SessionMessage.self, from: path)
        }
    }

    // MARK: - Private

    private func sessionDir(_ sessionId: String) -> URL {
        baseDir.appendingPathComponent("session_\(sessionId)")
    }

    private func agentDir(_ sessionId: String, _ agentId: String) -> URL {
        sessionDir(sessionId).appendingPathComponent("agents/agent_\(agentId)")
    }

    private func messagesDir(_ sessionId: String, _ agentId: String) -> URL {
        agentDir(sessionId, agentId).appendingPathComponent("messages")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    /// Write data to a temporary file, then atomically rename to the target.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmpURL = url.appendingPathExtension("tmp")
        try data.write(to: tmpURL)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }
}
