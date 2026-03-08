import Foundation

/// A tool created from a closure. The simplest way to define a tool.
///
/// ```swift
/// let calculator = FunctionTool(
///     name: "calculator",
///     description: "Evaluate a math expression",
///     inputSchema: [
///         "type": "object",
///         "properties": [
///             "expression": ["type": "string", "description": "Math expression to evaluate"]
///         ],
///         "required": ["expression"]
///     ]
/// ) { input, context in
///     let expr = input["expression"]
///     return "Result: \(expr ?? "unknown")"
/// }
/// ```
public struct FunctionTool: AgentTool {
    public let name: String
    public let toolSpec: ToolSpec

    private let handler: @Sendable (JSONValue, ToolContext) async throws -> ToolResultContent

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema = ["type": "object"],
        handler: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolResultContent
    ) {
        self.name = name
        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: inputSchema)
        self.handler = handler
    }

    /// String-returning convenience initializer.
    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema = ["type": "object"],
        handler: @escaping @Sendable (JSONValue, ToolContext) async throws -> String
    ) {
        self.name = name
        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: inputSchema)
        self.handler = { input, context in
            let result = try await handler(input, context)
            return .text(result)
        }
    }

    public func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        do {
            let content = try await handler(toolUse.input, context)
            return ToolResultBlock(
                toolUseId: toolUse.toolUseId,
                status: .success,
                content: [content]
            )
        } catch {
            return ToolResultBlock(
                toolUseId: toolUse.toolUseId,
                status: .error,
                content: [.text("Error: \(error.localizedDescription)")]
            )
        }
    }
}
