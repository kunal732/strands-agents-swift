import Foundation

// MARK: - ToolParam

/// Describes a single parameter in a tool definition.
///
/// Used with the simplified `FunctionTool` initializer that auto-generates
/// the JSON schema from a list of typed parameters.
///
/// ```swift
/// FunctionTool(name: "weather", description: "Get weather", params: [
///     .string("city"),
///     .string("unit", description: "celsius or fahrenheit", optional: true),
/// ]) { args in
///     getWeather(city: args.string("city"), unit: args.string("unit", default: "celsius"))
/// }
/// ```
public struct ToolParam: Sendable {
    public let name: String
    let jsonType: String
    let description: String
    let isOptional: Bool

    private init(_ name: String, jsonType: String, description: String, optional: Bool) {
        self.name = name
        self.jsonType = jsonType
        self.description = description
        self.isOptional = optional
    }

    public static func string(_ name: String, description: String = "", optional: Bool = false) -> ToolParam {
        ToolParam(name, jsonType: "string", description: description, optional: optional)
    }
    public static func int(_ name: String, description: String = "", optional: Bool = false) -> ToolParam {
        ToolParam(name, jsonType: "integer", description: description, optional: optional)
    }
    public static func double(_ name: String, description: String = "", optional: Bool = false) -> ToolParam {
        ToolParam(name, jsonType: "number", description: description, optional: optional)
    }
    public static func bool(_ name: String, description: String = "", optional: Bool = false) -> ToolParam {
        ToolParam(name, jsonType: "boolean", description: description, optional: optional)
    }
}

// MARK: - ToolArgs

/// Typed accessor for tool input arguments. Passed to the simplified
/// `FunctionTool` handler so you can read parameters without casting.
///
/// ```swift
/// } { args in
///     let city = args.string("city")
///     let count = args.int("count", default: 5)
///     let verbose = args.bool("verbose", default: false)
/// }
/// ```
public struct ToolArgs: Sendable {
    private let input: JSONValue

    init(_ input: JSONValue) { self.input = input }

    public func string(_ key: String, default fallback: String = "") -> String {
        input[key]?.foundationValue as? String ?? fallback
    }
    public func int(_ key: String, default fallback: Int = 0) -> Int {
        (input[key]?.foundationValue as? Int)
            ?? (input[key]?.foundationValue as? Double).map(Int.init)
            ?? fallback
    }
    public func double(_ key: String, default fallback: Double = 0) -> Double {
        input[key]?.foundationValue as? Double
            ?? (input[key]?.foundationValue as? Int).map(Double.init)
            ?? fallback
    }
    public func bool(_ key: String, default fallback: Bool = false) -> Bool {
        input[key]?.foundationValue as? Bool ?? fallback
    }
    public func optional(_ key: String) -> String? {
        input[key]?.foundationValue as? String
    }
}

// MARK: - FunctionTool

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

    /// Simplified initializer with typed params and ToolArgs accessor.
    ///
    /// Define params as a simple array -- the JSON schema is generated automatically.
    /// The handler receives a `ToolArgs` accessor for clean, typed argument reading.
    ///
    /// ```swift
    /// func wordCount(text: String) -> Int {
    ///     text.split(whereSeparator: \.isWhitespace).count
    /// }
    ///
    /// let wordCountTool = FunctionTool(
    ///     name: "word_count",
    ///     description: "Count the number of words in text.",
    ///     params: [.string("text")]
    /// ) { args in
    ///     wordCount(text: args.string("text"))
    /// }
    /// ```
    public init(
        name: String,
        description: String,
        params: [ToolParam],
        handler: @escaping @Sendable (ToolArgs) async throws -> String
    ) {
        self.name = name

        // Build JSON schema from params
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for param in params {
            var spec: [String: JSONValue] = ["type": .string(param.jsonType)]
            if !param.description.isEmpty { spec["description"] = .string(param.description) }
            properties[param.name] = .object(spec)
            if !param.isOptional { required.append(.string(param.name)) }
        }
        var schema: JSONSchema = [
            "type": "object",
            "properties": .object(properties),
        ]
        if !required.isEmpty { schema["required"] = .array(required) }

        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: schema)
        self.handler = { input, _ in
            let result = try await handler(ToolArgs(input))
            return .text(result)
        }
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
