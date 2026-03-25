import Foundation

// MARK: - JSONToolParam

/// A Swift type that maps to a JSON schema type for tool parameters.
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
        (json[key]?.foundationValue as? Int) ?? (json[key]?.foundationValue as? Double).map(Int.init) ?? 0
    }
}
extension Double: JSONToolParam {
    public static var jsonType: String { "number" }
    public static func extract(from json: JSONValue, key: String) -> Double {
        (json[key]?.foundationValue as? Double) ?? (json[key]?.foundationValue as? Int).map(Double.init) ?? 0
    }
}
extension Bool: JSONToolParam {
    public static var jsonType: String { "boolean" }
    public static func extract(from json: JSONValue, key: String) -> Bool {
        json[key]?.foundationValue as? Bool ?? false
    }
}

// MARK: - Tool

/// Define a tool from a Swift function and a description. Parameter names and
/// tool name are inferred by the model at startup and cached.
///
/// ```swift
/// func fetchWeather(city: String, unit: String) -> String {
///     "72°F in \(city)"
/// }
///
/// let weather = Tool(fetchWeather, "Get the current weather for a city.")
/// let agent = Agent(model: provider, tools: [weather])
/// ```
///
/// On the first `agent.run()`, the framework asks the model to name the
/// parameters (one batched call for all tools). The result is cached -- subsequent
/// runs skip inference entirely. Works offline with local MLX models.
///
/// Optionally override the tool name:
/// ```swift
/// let weather = Tool(fetchWeather, "Get weather.", name: "weather_api")
/// ```
public struct Tool: AgentTool, @unchecked Sendable {
    public private(set) var name: String
    public private(set) var toolSpec: ToolSpec

    /// Whether this tool still needs schema inference from the model.
    public var needsInference: Bool { !schemaResolved }

    private var schemaResolved: Bool
    private let description: String
    public let paramTypes: [String]   // ["string", "integer", etc.]
    private let handler: @Sendable (JSONValue) -> String
    private let nameOverride: String?

    // MARK: - 0 parameters

    public init(
        _ description: String,
        name: String? = nil,
        code: @escaping @Sendable () -> String
    ) {
        self.description = description
        self.nameOverride = name
        self.paramTypes = []
        self.handler = { _ in code() }

        let resolvedName = name ?? "tool_\(UUID().uuidString.prefix(8))"
        self.name = resolvedName
        self.toolSpec = ToolSpec(name: resolvedName, description: description, inputSchema: ["type": "object"])
        self.schemaResolved = name != nil
    }

    public init<R: CustomStringConvertible>(
        _ description: String,
        name: String? = nil,
        code: @escaping @Sendable () -> R
    ) {
        self.description = description
        self.nameOverride = name
        self.paramTypes = []
        self.handler = { _ in "\(code())" }

        let resolvedName = name ?? "tool_\(UUID().uuidString.prefix(8))"
        self.name = resolvedName
        self.toolSpec = ToolSpec(name: resolvedName, description: description, inputSchema: ["type": "object"])
        self.schemaResolved = name != nil
    }

    // MARK: - 1 parameter

    public init<A: JSONToolParam>(
        _ fn: @escaping @Sendable (A) -> String,
        _ description: String,
        name: String? = nil
    ) {
        self.description = description
        self.nameOverride = name
        self.paramTypes = [A.jsonType]
        self.handler = { json in
            // Param name will be resolved later; use first key or positional
            let key = json.firstKey ?? "arg0"
            return fn(A.extract(from: json, key: key))
        }

        let resolvedName = name ?? "tool_\(UUID().uuidString.prefix(8))"
        self.name = resolvedName
        self.toolSpec = ToolSpec(name: resolvedName, description: description, inputSchema: ["type": "object"])
        self.schemaResolved = false
    }

    public init<A: JSONToolParam, R: CustomStringConvertible>(
        _ fn: @escaping @Sendable (A) -> R,
        _ description: String,
        name: String? = nil
    ) {
        self.description = description
        self.nameOverride = name
        self.paramTypes = [A.jsonType]
        self.handler = { json in
            let key = json.firstKey ?? "arg0"
            return "\(fn(A.extract(from: json, key: key)))"
        }

        let resolvedName = name ?? "tool_\(UUID().uuidString.prefix(8))"
        self.name = resolvedName
        self.toolSpec = ToolSpec(name: resolvedName, description: description, inputSchema: ["type": "object"])
        self.schemaResolved = false
    }

    // MARK: - 2 parameters

    public init<A: JSONToolParam, B: JSONToolParam>(
        _ fn: @escaping @Sendable (A, B) -> String,
        _ description: String,
        name: String? = nil
    ) {
        self.description = description
        self.nameOverride = name
        self.paramTypes = [A.jsonType, B.jsonType]
        // Store fn for later; handler will be rebuilt after inference
        let storedFn = fn
        self.handler = { json in
            let keys = json.sortedKeys
            let a = A.extract(from: json, key: keys.count > 0 ? keys[0] : "arg0")
            let b = B.extract(from: json, key: keys.count > 1 ? keys[1] : "arg1")
            return storedFn(a, b)
        }

        let resolvedName = name ?? "tool_\(UUID().uuidString.prefix(8))"
        self.name = resolvedName
        self.toolSpec = ToolSpec(name: resolvedName, description: description, inputSchema: ["type": "object"])
        self.schemaResolved = false
    }

    public init<A: JSONToolParam, B: JSONToolParam, R: CustomStringConvertible>(
        _ fn: @escaping @Sendable (A, B) -> R,
        _ description: String,
        name: String? = nil
    ) {
        self.description = description
        self.nameOverride = name
        self.paramTypes = [A.jsonType, B.jsonType]
        let storedFn = fn
        self.handler = { json in
            let keys = json.sortedKeys
            let a = A.extract(from: json, key: keys.count > 0 ? keys[0] : "arg0")
            let b = B.extract(from: json, key: keys.count > 1 ? keys[1] : "arg1")
            return "\(storedFn(a, b))"
        }

        let resolvedName = name ?? "tool_\(UUID().uuidString.prefix(8))"
        self.name = resolvedName
        self.toolSpec = ToolSpec(name: resolvedName, description: description, inputSchema: ["type": "object"])
        self.schemaResolved = false
    }

    // MARK: - 3 parameters

    public init<A: JSONToolParam, B: JSONToolParam, C: JSONToolParam>(
        _ fn: @escaping @Sendable (A, B, C) -> String,
        _ description: String,
        name: String? = nil
    ) {
        self.description = description
        self.nameOverride = name
        self.paramTypes = [A.jsonType, B.jsonType, C.jsonType]
        let storedFn = fn
        self.handler = { json in
            let keys = json.sortedKeys
            let a = A.extract(from: json, key: keys.count > 0 ? keys[0] : "arg0")
            let b = B.extract(from: json, key: keys.count > 1 ? keys[1] : "arg1")
            let c = C.extract(from: json, key: keys.count > 2 ? keys[2] : "arg2")
            return storedFn(a, b, c)
        }

        let resolvedName = name ?? "tool_\(UUID().uuidString.prefix(8))"
        self.name = resolvedName
        self.toolSpec = ToolSpec(name: resolvedName, description: description, inputSchema: ["type": "object"])
        self.schemaResolved = false
    }

    // MARK: - Schema Resolution

    /// Called by the agent to apply inferred parameter names and tool name.
    public mutating func resolveSchema(toolName: String, paramNames: [String]) {
        let finalName = nameOverride ?? toolName
        self.name = finalName

        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for (i, paramName) in paramNames.enumerated() {
            let jsonType = i < paramTypes.count ? paramTypes[i] : "string"
            properties[paramName] = .object(["type": .string(jsonType)])
            required.append(.string(paramName))
        }

        var schema: JSONSchema = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required) }

        self.toolSpec = ToolSpec(name: finalName, description: description, inputSchema: schema)
        self.schemaResolved = true
    }

    // MARK: - Execution

    public func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        let result = handler(toolUse.input)
        return ToolResultBlock(toolUseId: toolUse.toolUseId, status: .success, content: [.text(result)])
    }
}

// MARK: - JSONValue helpers

extension JSONValue {
    var firstKey: String? {
        guard case .object(let dict) = self else { return nil }
        return dict.keys.sorted().first
    }

    var sortedKeys: [String] {
        guard case .object(let dict) = self else { return [] }
        return dict.keys.sorted()
    }
}

// MARK: - Tool Schema Inference

/// Generates tool schemas by asking the model to name parameters.
/// Called once at agent startup for tools that need inference. Results are cached.
public enum ToolSchemaInference {

    /// Build the inference prompt for a batch of tools.
    public static func buildInferencePrompt(tools: [(index: Int, description: String, paramTypes: [String])]) -> String {
        var prompt = "You are a tool naming assistant. For each tool below, suggest a short snake_case tool name and parameter names based on the description and parameter types.\n\n"
        prompt += "Return ONLY valid JSON in this format:\n"
        prompt += "[{\"name\": \"tool_name\", \"params\": [\"param1\", \"param2\"]}]\n\n"
        prompt += "Tools:\n"

        for tool in tools {
            let types = tool.paramTypes.isEmpty ? "none" : tool.paramTypes.joined(separator: ", ")
            prompt += "\(tool.index + 1). Description: \"\(tool.description)\" | Parameters: (\(types))\n"
        }

        return prompt
    }

    /// Parse the model's response into tool schemas.
    public static func parseInferenceResponse(_ response: String) -> [(name: String, params: [String])]? {
        // Find JSON array in the response
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]") else { return nil }

        let jsonString = String(response[start...end])
        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        return array.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let params = dict["params"] as? [String] else { return nil }
            return (name: name, params: params)
        }
    }
}
