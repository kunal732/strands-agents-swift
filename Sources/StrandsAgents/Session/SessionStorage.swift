import Foundation

/// Storage backend for persisting agent sessions.
public protocol SessionStorage: Sendable {
    func save(sessionId: String, data: Data) async throws
    func load(sessionId: String) async throws -> Data?
    func delete(sessionId: String) async throws
    func list() async throws -> [String]
}

/// Stores sessions as files on disk.
public struct FileSessionStorage: SessionStorage {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(sessionId: String, data: Data) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = directory.appendingPathComponent("\(sessionId).json")
        try data.write(to: url)
    }

    public func load(sessionId: String) async throws -> Data? {
        let url = directory.appendingPathComponent("\(sessionId).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func delete(sessionId: String) async throws {
        let url = directory.appendingPathComponent("\(sessionId).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func list() async throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
    }
}
