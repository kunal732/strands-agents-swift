import Foundation

/// Protocol for types that can be used as structured output from an agent.
///
/// Conforming types must be `Codable` and provide a JSON schema describing
/// their structure. The agent will force the model to produce output matching
/// this schema by using a hidden tool.
///
/// ```swift
/// struct WeatherReport: StructuredOutput {
///     let city: String
///     let temperature: Double
///     let condition: String
///
///     static var jsonSchema: JSONSchema {
///         [
///             "type": "object",
///             "properties": [
///                 "city": ["type": "string"],
///                 "temperature": ["type": "number"],
///                 "condition": ["type": "string"],
///             ],
///             "required": ["city", "temperature", "condition"],
///         ]
///     }
/// }
///
/// let result: WeatherReport = try await agent.runStructured("What's the weather in SF?")
/// ```
public protocol StructuredOutput: Codable, Sendable {
    /// JSON Schema describing this type's structure.
    static var jsonSchema: JSONSchema { get }
}

/// Internal tool used to enforce structured output from the model.
struct StructuredOutputTool: AgentTool {
    let name = "_structured_output"
    let outputType: any StructuredOutput.Type

    var toolSpec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Respond with structured output matching the required schema. Always use this tool to provide your final answer.",
            inputSchema: outputType.jsonSchema
        )
    }

    func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        // Validate the input can decode to the expected type
        let data = try JSONEncoder().encode(toolUse.input)
        _ = try JSONDecoder().decode(outputType, from: data)

        // Return success -- the actual parsing happens in Agent.runStructured
        return ToolResultBlock(
            toolUseId: toolUse.toolUseId,
            status: .success,
            content: [.text("Output accepted.")]
        )
    }
}

/// Errors related to structured output.
extension StrandsError {
    /// Create a structured output validation error.
    static func structuredOutputFailed(reason: String) -> StrandsError {
        .invalidToolInput(name: "_structured_output", reason: reason)
    }
}
