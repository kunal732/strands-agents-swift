/// A source of tools that can be loaded into a `ToolRegistry`.
///
/// Use this to group related tools together, load tools from external sources,
/// or implement dynamic tool discovery (e.g. MCP servers).
///
/// ```swift
/// struct MathToolProvider: ToolProvider {
///     func loadTools() async throws -> [any AgentTool] {
///         [CalculatorTool(), UnitConverterTool(), StatisticsTool()]
///     }
/// }
///
/// let agent = Agent(model: provider, toolProviders: [MathToolProvider()])
/// ```
public protocol ToolProvider: Sendable {
    /// Load and return tools from this provider.
    func loadTools() async throws -> [any AgentTool]
}

// MARK: - Static Tool Provider

/// A simple tool provider that wraps a fixed list of tools.
public struct StaticToolProvider: ToolProvider {
    private let tools: [any AgentTool]

    public init(tools: [any AgentTool]) {
        self.tools = tools
    }

    public func loadTools() async throws -> [any AgentTool] {
        tools
    }
}

// MARK: - ToolRegistry Extension

extension ToolRegistry {
    /// Load tools from a provider and register them.
    public func loadFrom(_ provider: any ToolProvider) async throws {
        let tools = try await provider.loadTools()
        for tool in tools {
            register(tool)
        }
    }
}
