import Foundation

/// Manages registration and lookup of tools available to an agent.
public final class ToolRegistry: @unchecked Sendable {
    private var tools: [String: any AgentTool] = [:]
    private let lock = NSLock()

    /// Regex pattern for valid tool names.
    private nonisolated(unsafe) static let validNamePattern = /^[a-zA-Z0-9_\-]{1,64}$/

    public init() {}

    /// Initialize with a list of tools.
    public init(tools: [any AgentTool]) {
        for tool in tools {
            self.tools[tool.name] = tool
        }
    }

    /// Register a tool. Replaces any existing tool with the same name.
    ///
    /// - Throws: Logs a warning if the tool name doesn't match the valid pattern.
    public func register(_ tool: any AgentTool) {
        if !Self.isValidToolName(tool.name) {
            // Log but don't throw -- some internal tools may have special names
            #if DEBUG
            print("[StrandsAgents] Warning: Tool name '\(tool.name)' doesn't match pattern ^[a-zA-Z0-9_-]{1,64}$")
            #endif
        }
        lock.withLock {
            tools[tool.name] = tool
        }
    }

    /// Unregister a tool by name.
    @discardableResult
    public func unregister(name: String) -> (any AgentTool)? {
        lock.withLock {
            tools.removeValue(forKey: name)
        }
    }

    /// Look up a tool by name.
    public func tool(named name: String) -> (any AgentTool)? {
        lock.withLock { tools[name] }
    }

    /// All registered tool specifications (for passing to the model).
    public var toolSpecs: [ToolSpec] {
        lock.withLock {
            tools.values.map(\.toolSpec)
        }
    }

    /// All registered tool names.
    public var toolNames: [String] {
        lock.withLock { Array(tools.keys) }
    }

    /// Number of registered tools.
    public var count: Int {
        lock.withLock { tools.count }
    }

    /// All registered tools in insertion order (for schema inference).
    public var allTools: [any AgentTool] {
        lock.withLock { Array(tools.values) }
    }

    /// Replace a tool at a logical index (used after schema inference resolves a Tool).
    public func updateTool(at index: Int, with tool: any AgentTool) {
        lock.withLock {
            // Remove old entry with the placeholder name and register the resolved one
            let keys = Array(tools.keys)
            if index < keys.count {
                tools.removeValue(forKey: keys[index])
            }
            tools[tool.name] = tool
        }
    }

    /// Validate a tool name against the standard pattern.
    public static func isValidToolName(_ name: String) -> Bool {
        name.wholeMatch(of: validNamePattern) != nil
    }
}
