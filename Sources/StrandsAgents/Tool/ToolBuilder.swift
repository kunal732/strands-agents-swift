import Foundation

/// Build tool input schemas declaratively using a result builder.
///
/// Instead of writing raw JSON schemas, use `ToolSchemaBuilder` for type-safe
/// schema construction:
///
/// ```swift
/// let tool = FunctionTool(
///     name: "get_weather",
///     description: "Get current weather",
///     inputSchema: ToolSchemaBuilder.build {
///         StringProperty("city", description: "The city name")
///             .required()
///         StringProperty("unit", description: "Temperature unit")
///             .enum(["celsius", "fahrenheit"])
///     }
/// ) { input, context in
///     let city = input["city"]?.foundationValue as? String ?? ""
///     return "Weather in \(city): 72F"
/// }
/// ```
public enum ToolSchemaBuilder {

    /// Build a JSON Schema from property definitions.
    public static func build(@PropertyBuilder _ content: () -> [PropertyDefinition]) -> JSONSchema {
        let properties = content()
        var propsDict: [String: JSONValue] = [:]
        var required: [JSONValue] = []

        for prop in properties {
            propsDict[prop.name] = .object(prop.schema)
            if prop.isRequired {
                required.append(.string(prop.name))
            }
        }

        var schema: JSONSchema = [
            "type": "object",
            "properties": .object(propsDict),
        ]

        if !required.isEmpty {
            schema["required"] = .array(required)
        }

        return schema
    }
}

// MARK: - Property Definitions

/// A property in a tool input schema.
public struct PropertyDefinition {
    public let name: String
    public var schema: [String: JSONValue]
    public var isRequired: Bool

    public init(name: String, schema: [String: JSONValue], isRequired: Bool = false) {
        self.name = name
        self.schema = schema
        self.isRequired = isRequired
    }

    /// Mark this property as required.
    public func required() -> PropertyDefinition {
        var copy = self
        copy.isRequired = true
        return copy
    }
}

/// A string property.
public func StringProperty(_ name: String, description: String) -> PropertyDefinition {
    PropertyDefinition(name: name, schema: [
        "type": .string("string"),
        "description": .string(description),
    ])
}

/// A number property.
public func NumberProperty(_ name: String, description: String) -> PropertyDefinition {
    PropertyDefinition(name: name, schema: [
        "type": .string("number"),
        "description": .string(description),
    ])
}

/// An integer property.
public func IntegerProperty(_ name: String, description: String) -> PropertyDefinition {
    PropertyDefinition(name: name, schema: [
        "type": .string("integer"),
        "description": .string(description),
    ])
}

/// A boolean property.
public func BooleanProperty(_ name: String, description: String) -> PropertyDefinition {
    PropertyDefinition(name: name, schema: [
        "type": .string("boolean"),
        "description": .string(description),
    ])
}

/// An array property.
public func ArrayProperty(_ name: String, description: String, itemType: String = "string") -> PropertyDefinition {
    PropertyDefinition(name: name, schema: [
        "type": .string("array"),
        "description": .string(description),
        "items": .object(["type": .string(itemType)]),
    ])
}

// MARK: - Property Modifiers

extension PropertyDefinition {
    /// Add enum constraints.
    public func `enum`(_ values: [String]) -> PropertyDefinition {
        var copy = self
        copy.schema["enum"] = .array(values.map { .string($0) })
        return copy
    }

    /// Add a default value.
    public func defaultValue(_ value: JSONValue) -> PropertyDefinition {
        var copy = self
        copy.schema["default"] = value
        return copy
    }

    /// Set minimum value (for numbers).
    public func minimum(_ value: Double) -> PropertyDefinition {
        var copy = self
        copy.schema["minimum"] = .double(value)
        return copy
    }

    /// Set maximum value (for numbers).
    public func maximum(_ value: Double) -> PropertyDefinition {
        var copy = self
        copy.schema["maximum"] = .double(value)
        return copy
    }
}

// MARK: - Result Builder

@resultBuilder
public struct PropertyBuilder {
    public static func buildBlock(_ components: PropertyDefinition...) -> [PropertyDefinition] {
        components
    }
}
