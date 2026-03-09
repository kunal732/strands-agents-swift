import Foundation

/// S3-backed session repository.
///
/// Uses the same directory structure as `FileSessionRepository` but stored
/// as S3 objects. Messages are loaded in parallel for performance.
///
/// ```swift
/// let repo = S3SessionRepository(
///     bucket: "my-app-sessions",
///     prefix: "users/user-123/",
///     signer: myAWSSigner
/// )
/// let manager = RepositorySessionManager(sessionId: "session-1", repository: repo)
/// ```
public struct S3SessionRepository: SessionRepository {
    private let bucket: String
    private let prefix: String
    private let region: String
    private let signer: (any S3RequestSigner)?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        bucket: String,
        prefix: String = "",
        region: String = "us-east-1",
        signer: (any S3RequestSigner)? = nil
    ) {
        self.bucket = bucket
        self.prefix = prefix
        self.region = region
        self.signer = signer
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Session

    public func createSession(sessionId: String, data: SessionData) async throws {
        try await putObject(key: sessionKey(sessionId, "session.json"), data: encode(data))
    }

    public func readSession(sessionId: String) async throws -> SessionData? {
        guard let data = try await getObject(key: sessionKey(sessionId, "session.json")) else { return nil }
        return try decoder.decode(SessionData.self, from: data)
    }

    public func deleteSession(sessionId: String) async throws {
        // List all objects with the session prefix, then delete them
        let prefix = sessionKey(sessionId, "")
        let keys = try await listObjectKeys(prefix: prefix)
        for key in keys {
            try await deleteObject(key: key)
        }
    }

    // MARK: - Agent

    public func updateAgent(sessionId: String, agentId: String, state: AgentSessionState) async throws {
        let key = sessionKey(sessionId, "agents/agent_\(agentId)/agent.json")
        try await putObject(key: key, data: encode(state))
    }

    public func readAgent(sessionId: String, agentId: String) async throws -> AgentSessionState? {
        let key = sessionKey(sessionId, "agents/agent_\(agentId)/agent.json")
        guard let data = try await getObject(key: key) else { return nil }
        return try decoder.decode(AgentSessionState.self, from: data)
    }

    // MARK: - Messages

    public func createMessage(sessionId: String, agentId: String, index: Int, message: SessionMessage) async throws {
        let key = messageKey(sessionId, agentId, index)
        try await putObject(key: key, data: encode(message))
    }

    public func readMessage(sessionId: String, agentId: String, index: Int) async throws -> SessionMessage? {
        let key = messageKey(sessionId, agentId, index)
        guard let data = try await getObject(key: key) else { return nil }
        return try decoder.decode(SessionMessage.self, from: data)
    }

    public func updateMessage(sessionId: String, agentId: String, index: Int, message: SessionMessage) async throws {
        try await createMessage(sessionId: sessionId, agentId: agentId, index: index, message: message)
    }

    public func listMessages(sessionId: String, agentId: String, offset: Int, limit: Int?) async throws -> [SessionMessage] {
        let prefix = sessionKey(sessionId, "agents/agent_\(agentId)/messages/")
        let keys = try await listObjectKeys(prefix: prefix)

        // Extract indices and sort
        let indexed = keys.compactMap { key -> (Int, String)? in
            let filename = key.components(separatedBy: "/").last ?? ""
            let name = filename.replacingOccurrences(of: "message_", with: "")
                .replacingOccurrences(of: ".json", with: "")
            guard let index = Int(name) else { return nil }
            return (index, key)
        }.sorted { $0.0 < $1.0 }

        // Apply pagination
        let sliced: [(Int, String)]
        if let limit {
            sliced = Array(indexed.dropFirst(offset).prefix(limit))
        } else {
            sliced = Array(indexed.dropFirst(offset))
        }

        // Load messages in parallel
        return try await withThrowingTaskGroup(of: (Int, SessionMessage?).self) { group in
            for (index, key) in sliced {
                group.addTask {
                    guard let data = try await self.getObject(key: key) else { return (index, nil) }
                    let msg = try self.decoder.decode(SessionMessage.self, from: data)
                    return (index, msg)
                }
            }

            var results: [(Int, SessionMessage?)] = []
            for try await pair in group {
                results.append(pair)
            }

            return results
                .sorted { $0.0 < $1.0 }
                .compactMap(\.1)
        }
    }

    // MARK: - S3 Operations

    private func putObject(key: String, data: Data) async throws {
        var request = URLRequest(url: s3URL(key: key))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        if let signer { request = try await signer.sign(request) }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StrandsError.serializationFailed(
                underlying: NSError(domain: "S3", code: -1, userInfo: [NSLocalizedDescriptionKey: "S3 PUT failed"])
            )
        }
    }

    private func getObject(key: String) async throws -> Data? {
        var request = URLRequest(url: s3URL(key: key))
        request.httpMethod = "GET"
        if let signer { request = try await signer.sign(request) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private func deleteObject(key: String) async throws {
        var request = URLRequest(url: s3URL(key: key))
        request.httpMethod = "DELETE"
        if let signer { request = try await signer.sign(request) }
        let (_, _) = try await session.data(for: request)
    }

    private func listObjectKeys(prefix: String) async throws -> [String] {
        var request = URLRequest(url: URL(
            string: "https://\(bucket).s3.\(region).amazonaws.com/?list-type=2&prefix=\(prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prefix)"
        )!)
        request.httpMethod = "GET"
        if let signer { request = try await signer.sign(request) }
        let (data, _) = try await session.data(for: request)
        let xml = String(data: data, encoding: .utf8) ?? ""
        return xml.components(separatedBy: "<Key>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</Key>").first }
    }

    // MARK: - Helpers

    private func sessionKey(_ sessionId: String, _ path: String) -> String {
        "\(prefix)session_\(sessionId)/\(path)"
    }

    private func messageKey(_ sessionId: String, _ agentId: String, _ index: Int) -> String {
        sessionKey(sessionId, "agents/agent_\(agentId)/messages/message_\(index).json")
    }

    private func s3URL(key: String) -> URL {
        URL(string: "https://\(bucket).s3.\(region).amazonaws.com/\(key)")!
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }
}
