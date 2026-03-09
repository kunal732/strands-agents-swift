import Foundation

/// Key-value store for arbitrary agent state that persists across invocations.
///
/// Unlike conversation messages, state is not passed to the model. It is available
/// to tools via `ToolContext` and can be serialized for session persistence.
///
/// ```swift
/// agent.state["user_preference"] = .string("dark_mode")
/// let pref = agent.state["user_preference"]
/// ```
public final class AgentState: @unchecked Sendable {
    private var storage: [String: JSONValue] = [:]
    private let lock = NSLock()

    public init() {}

    public subscript(key: String) -> JSONValue? {
        get {
            lock.withLock { storage[key] }
        }
        set {
            lock.withLock { storage[key] = newValue }
        }
    }

    /// Remove a value by key.
    @discardableResult
    public func remove(_ key: String) -> JSONValue? {
        lock.withLock { storage.removeValue(forKey: key) }
    }

    /// Remove all stored values.
    public func removeAll() {
        lock.withLock { storage.removeAll() }
    }

    /// All stored key-value pairs.
    public var all: [String: JSONValue] {
        lock.withLock { storage }
    }

    /// Whether the state contains a given key.
    public func contains(_ key: String) -> Bool {
        lock.withLock { storage[key] != nil }
    }
}
