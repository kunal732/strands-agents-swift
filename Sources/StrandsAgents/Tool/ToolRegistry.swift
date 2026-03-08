/// Manages registration and lookup of tools available to an agent.
public final class ToolRegistry: @unchecked Sendable {
    private var tools: [String: any AgentTool] = [:]
    private let lock = NSLock()

    public init() {}

    /// Initialize with a list of tools.
    public init(tools: [any AgentTool]) {
        for tool in tools {
            self.tools[tool.name] = tool
        }
    }

    /// Register a tool. Replaces any existing tool with the same name.
    public func register(_ tool: any AgentTool) {
        lock.lock()
        defer { lock.unlock() }
        tools[tool.name] = tool
    }

    /// Unregister a tool by name.
    @discardableResult
    public func unregister(name: String) -> (any AgentTool)? {
        lock.lock()
        defer { lock.unlock() }
        return tools.removeValue(forKey: name)
    }

    /// Look up a tool by name.
    public func tool(named name: String) -> (any AgentTool)? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }

    /// All registered tool specifications (for passing to the model).
    public var toolSpecs: [ToolSpec] {
        lock.lock()
        defer { lock.unlock() }
        return tools.values.map(\.toolSpec)
    }

    /// All registered tool names.
    public var toolNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tools.keys)
    }

    /// Number of registered tools.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return tools.count
    }
}

import Foundation
