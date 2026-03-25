import Foundation

// MARK: - JSONToolParam

/// A Swift type that maps to a JSON schema type for tool parameters.
public protocol JSONToolParam: Sendable {
    static var jsonType: String { get }
}

extension String: JSONToolParam  { public static var jsonType: String { "string" } }
extension Int: JSONToolParam     { public static var jsonType: String { "integer" } }
extension Double: JSONToolParam  { public static var jsonType: String { "number" } }
extension Bool: JSONToolParam    { public static var jsonType: String { "boolean" } }

// MARK: - ToolInput

/// Typed accessor for tool parameters that also auto-discovers the schema.
///
/// When a `Tool` is created, the handler runs once in "recording" mode.
/// Every `.string()`, `.int()`, `.double()`, `.bool()` call records the
/// parameter name and type. The JSON schema is built from those recordings.
///
/// During real execution, the same calls extract values from the model's JSON.
///
/// ```swift
/// Tool("calculator", "Evaluate a math expression.") { args in
///     let expression = args.string("expression")
///     // Schema: {"expression": {"type": "string"}}
///     return eval(expression)
/// }
/// ```
public final class ToolInput: @unchecked Sendable {
    private let json: JSONValue?
    private let recording: Bool
    private(set) var params: [(name: String, type: String)] = []

    init(recording: Bool) {
        self.json = nil
        self.recording = true
    }

    init(json: JSONValue) {
        self.json = json
        self.recording = false
    }

    /// Read a string parameter.
    public func string(_ key: String, default fallback: String = "") -> String {
        if recording { params.append((key, "string")); return fallback }
        return json?[key]?.foundationValue as? String ?? fallback
    }

    /// Read an integer parameter.
    public func int(_ key: String, default fallback: Int = 0) -> Int {
        if recording { params.append((key, "integer")); return fallback }
        return (json?[key]?.foundationValue as? Int)
            ?? (json?[key]?.foundationValue as? Double).map(Int.init)
            ?? fallback
    }

    /// Read a floating-point parameter.
    public func double(_ key: String, default fallback: Double = 0) -> Double {
        if recording { params.append((key, "number")); return fallback }
        return (json?[key]?.foundationValue as? Double)
            ?? (json?[key]?.foundationValue as? Int).map(Double.init)
            ?? fallback
    }

    /// Read a boolean parameter.
    public func bool(_ key: String, default fallback: Bool = false) -> Bool {
        if recording { params.append((key, "boolean")); return fallback }
        return json?[key]?.foundationValue as? Bool ?? fallback
    }
}

// MARK: - Tool

/// Define a tool from a name, description, and handler. The parameter schema
/// is auto-discovered from the handler -- no manual schema or params needed.
///
/// ```swift
/// let weatherTool = Tool("get_weather", "Get the current weather for a city.") { args in
///     let city = args.string("city")
///     let unit = args.string("unit")
///     return "\(Int.random(in: 60...90))°F in \(city)"
/// }
/// // Schema auto-generated: {"city": "string", "unit": "string"}
///
/// let agent = Agent(model: provider, tools: [weatherTool])
/// ```
///
/// Each `args.string()`, `args.int()`, `args.double()`, `args.bool()` call
/// simultaneously declares a parameter (for the schema) and reads its value
/// (during execution). Write the handler once -- the schema comes for free.
public struct Tool: AgentTool, Sendable {
    public let name: String
    public let toolSpec: ToolSpec
    private let handler: @Sendable (JSONValue) -> String

    /// Create a tool with auto-discovered schema.
    ///
    /// The handler runs once at init time in "recording" mode to discover
    /// parameter names and types. During real execution it runs normally.
    public init(
        _ name: String,
        _ description: String,
        handler: @escaping @Sendable (ToolInput) -> String
    ) {
        self.name = name

        // Dry-run the handler to discover params
        let recorder = ToolInput(recording: true)
        _ = handler(recorder)

        // Build JSON schema from recorded params
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for (paramName, paramType) in recorder.params {
            properties[paramName] = .object(["type": .string(paramType)])
            required.append(.string(paramName))
        }
        var schema: JSONSchema = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required) }

        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: schema)
        self.handler = { json in handler(ToolInput(json: json)) }
    }

    public func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        let result = handler(toolUse.input)
        return ToolResultBlock(toolUseId: toolUse.toolUseId, status: .success, content: [.text(result)])
    }
}
