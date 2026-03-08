/// Specification of a tool that can be provided to a model.
public struct ToolSpec: Sendable, Codable {
    /// Unique tool name. Must match `^[a-zA-Z0-9_-]{1,64}$`.
    public var name: String

    /// Human-readable description of what the tool does.
    public var description: String

    /// JSON Schema describing the tool's input parameters.
    public var inputSchema: JSONSchema

    /// Optional JSON Schema describing the tool's output.
    public var outputSchema: JSONSchema?

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        outputSchema: JSONSchema? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

/// Controls how the model selects tools.
public enum ToolChoice: Sendable, Codable {
    /// Model decides whether to use tools.
    case auto

    /// Model must use at least one tool.
    case any

    /// Model must use the specified tool.
    case tool(name: String)

    /// Model must not use any tools.
    case none
}
