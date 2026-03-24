import Foundation

// MARK: - JSONToolParam

/// A Swift type that can be used as a tool parameter.
/// Handles JSON encoding/decoding and schema type string automatically.
public protocol JSONToolParam: Sendable {
    static var jsonType: String { get }
    static func extract(from json: JSONValue, key: String) -> Self
}

extension String: JSONToolParam {
    public static var jsonType: String { "string" }
    public static func extract(from json: JSONValue, key: String) -> String {
        json[key]?.foundationValue as? String ?? ""
    }
}

extension Int: JSONToolParam {
    public static var jsonType: String { "integer" }
    public static func extract(from json: JSONValue, key: String) -> Int {
        (json[key]?.foundationValue as? Int)
            ?? (json[key]?.foundationValue as? Double).map(Int.init)
            ?? 0
    }
}

extension Double: JSONToolParam {
    public static var jsonType: String { "number" }
    public static func extract(from json: JSONValue, key: String) -> Double {
        (json[key]?.foundationValue as? Double)
            ?? (json[key]?.foundationValue as? Int).map(Double.init)
            ?? 0
    }
}

extension Bool: JSONToolParam {
    public static var jsonType: String { "boolean" }
    public static func extract(from json: JSONValue, key: String) -> Bool {
        json[key]?.foundationValue as? Bool ?? false
    }
}

// MARK: - Tool

/// Create a tool directly from a Swift function.
///
/// Pass your function as `code` and list the parameter names in `params`.
/// Types and schema are inferred automatically -- no manual JSON needed.
///
/// ```swift
/// func fetchWeather(city: String, unit: String) -> String {
///     "22°C in \(city)"
/// }
///
/// let weatherTool = Tool(
///     name: "get_weather",
///     description: "Get the current weather for a city.",
///     params: ("city", "unit"),
///     code: fetchWeather
/// )
/// ```
public struct Tool: AgentTool {
    public let name: String
    public let toolSpec: ToolSpec
    private let handler: @Sendable (JSONValue) async throws -> String

    public func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        do {
            let result = try await handler(toolUse.input)
            return ToolResultBlock(toolUseId: toolUse.toolUseId, status: .success, content: [.text(result)])
        } catch {
            return ToolResultBlock(toolUseId: toolUse.toolUseId, status: .error, content: [.text(error.localizedDescription)])
        }
    }

    // MARK: - 1 parameter

    public init<A: JSONToolParam>(
        name: String,
        description: String,
        params p: String,
        code: @escaping @Sendable (A) -> String
    ) {
        self.name = name
        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: Self.schema([(p, A.jsonType)]))
        self.handler = { json in code(A.extract(from: json, key: p)) }
    }

    public init<A: JSONToolParam, R: CustomStringConvertible>(
        name: String,
        description: String,
        params p: String,
        code: @escaping @Sendable (A) -> R
    ) {
        self.name = name
        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: Self.schema([(p, A.jsonType)]))
        self.handler = { json in "\(code(A.extract(from: json, key: p)))" }
    }

    // MARK: - 2 parameters

    public init<A: JSONToolParam, B: JSONToolParam>(
        name: String,
        description: String,
        params p: (String, String),
        code: @escaping @Sendable (A, B) -> String
    ) {
        self.name = name
        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: Self.schema([(p.0, A.jsonType), (p.1, B.jsonType)]))
        self.handler = { json in code(A.extract(from: json, key: p.0), B.extract(from: json, key: p.1)) }
    }

    public init<A: JSONToolParam, B: JSONToolParam, R: CustomStringConvertible>(
        name: String,
        description: String,
        params p: (String, String),
        code: @escaping @Sendable (A, B) -> R
    ) {
        self.name = name
        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: Self.schema([(p.0, A.jsonType), (p.1, B.jsonType)]))
        self.handler = { json in "\(code(A.extract(from: json, key: p.0), B.extract(from: json, key: p.1)))" }
    }

    // MARK: - 3 parameters

    public init<A: JSONToolParam, B: JSONToolParam, C: JSONToolParam>(
        name: String,
        description: String,
        params p: (String, String, String),
        code: @escaping @Sendable (A, B, C) -> String
    ) {
        self.name = name
        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: Self.schema([(p.0, A.jsonType), (p.1, B.jsonType), (p.2, C.jsonType)]))
        self.handler = { json in code(A.extract(from: json, key: p.0), B.extract(from: json, key: p.1), C.extract(from: json, key: p.2)) }
    }

    public init<A: JSONToolParam, B: JSONToolParam, C: JSONToolParam, R: CustomStringConvertible>(
        name: String,
        description: String,
        params p: (String, String, String),
        code: @escaping @Sendable (A, B, C) -> R
    ) {
        self.name = name
        self.toolSpec = ToolSpec(name: name, description: description, inputSchema: Self.schema([(p.0, A.jsonType), (p.1, B.jsonType), (p.2, C.jsonType)]))
        self.handler = { json in "\(code(A.extract(from: json, key: p.0), B.extract(from: json, key: p.1), C.extract(from: json, key: p.2)))" }
    }

    // MARK: - Schema builder

    private static func schema(_ params: [(name: String, type: String)]) -> JSONSchema {
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for (name, type) in params {
            properties[name] = .object(["type": .string(type)])
            required.append(.string(name))
        }
        return [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required),
        ]
    }
}
