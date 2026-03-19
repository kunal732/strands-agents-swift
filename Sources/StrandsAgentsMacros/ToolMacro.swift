import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// The `@Tool` macro implementation.
///
/// Transforms an annotated function into a type conforming to `AgentTool`.
///
/// Input:
/// ```swift
/// @Tool
/// func getWeather(city: String, unit: String = "fahrenheit") async throws -> String {
///     return "72F, sunny in \(city)"
/// }
/// ```
///
/// Expansion:
/// ```swift
/// func getWeather(city: String, unit: String = "fahrenheit") async throws -> String {
///     return "72F, sunny in \(city)"
/// }
///
/// let _tool_getWeather: any AgentTool = _GeneratedTool_getWeather()
///
/// struct _GeneratedTool_getWeather: AgentTool {
///     let name = "get_weather"
///     var toolSpec: ToolSpec {
///         ToolSpec(name: "get_weather", description: "...", inputSchema: [...])
///     }
///     func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock { ... }
/// }
/// ```
public struct ToolMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@Tool can only be applied to functions")
        }

        let funcName = funcDecl.name.text
        let toolName = funcName.camelCaseToSnakeCase()
        let structName = "_GeneratedTool_\(funcName)"

        // Extract parameters
        let params = funcDecl.signature.parameterClause.parameters

        // Build JSON schema properties
        var properties: [String] = []
        var required: [String] = []
        var decodingLines: [String] = []

        for param in params {
            let paramName = (param.secondName ?? param.firstName).text
            let typeText = param.type.trimmedDescription

            let jsonType = swiftTypeToJSONType(typeText)
            let isOptional = typeText.hasSuffix("?") || param.defaultValue != nil

            properties.append("""
                "\(paramName)": .object(["type": .string("\(jsonType)")])
            """)

            if !isOptional {
                required.append(".string(\"\(paramName)\")")
            }

            // Decoding line
            if isOptional && typeText.hasSuffix("?") {
                decodingLines.append("let \(paramName) = try? container.decode(\(typeText.replacingOccurrences(of: "?", with: "")).self, forKey: .\(paramName))")
            } else if let defaultValue = param.defaultValue {
                decodingLines.append("let \(paramName) = (try? container.decode(\(typeText).self, forKey: .\(paramName))) ?? \(defaultValue.value.trimmedDescription)")
            } else {
                decodingLines.append("let \(paramName) = try container.decode(\(typeText).self, forKey: .\(paramName))")
            }
        }

        // Extract description from doc comment if available
        let description = extractDescription(from: funcDecl)

        // Build the input struct
        let codingKeys = params.map { p in
            let name = (p.secondName ?? p.firstName).text
            return "case \(name)"
        }.joined(separator: "\n            ")

        let decodingBlock = decodingLines.joined(separator: "\n            ")

        let paramNames = params.map { ($0.secondName ?? $0.firstName).text }
        let callArgs = paramNames.map { "\($0): \($0)" }.joined(separator: ", ")

        let propertiesStr = properties.joined(separator: ",\n                ")
        let requiredStr = required.isEmpty ? "" : ",\n            \"required\": .array([\(required.joined(separator: ", "))])"

        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrowing = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        let awaitKeyword = isAsync ? "await " : ""
        let tryKeyword = isThrowing ? "try " : ""

        let generatedStruct: DeclSyntax = """
        struct \(raw: structName): AgentTool, Sendable {
            let name = "\(raw: toolName)"
            var toolSpec: ToolSpec {
                ToolSpec(
                    name: "\(raw: toolName)",
                    description: "\(raw: description)",
                    inputSchema: [
                        "type": "object",
                        "properties": .object([
                            \(raw: propertiesStr)
                        ])\(raw: requiredStr)
                    ]
                )
            }

            func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
                do {
                    let data = try JSONEncoder().encode(toolUse.input)
                    enum CodingKeys: String, CodingKey {
                        \(raw: codingKeys)
                    }
                    let container = try JSONDecoder().decode([String: JSONValue].self, from: data)
                    // Decode each parameter
                    let decoded = try JSONDecoder().decode(DecodableInput.self, from: data)
                    let result = \(raw: tryKeyword)\(raw: awaitKeyword)\(raw: funcName)(\(raw: callArgs.replacingOccurrences(of: ": ", with: ": decoded.")))
                    return ToolResultBlock(toolUseId: toolUse.toolUseId, status: .success, content: [.text("\\(result)")])
                } catch {
                    return ToolResultBlock(toolUseId: toolUse.toolUseId, status: .error, content: [.text("Error: \\(error.localizedDescription)")])
                }
            }

            struct DecodableInput: Codable {
                \(raw: params.map { p in
                    let name = (p.secondName ?? p.firstName).text
                    let type = p.type.trimmedDescription
                    if let dv = p.defaultValue {
                        return "var \(name): \(type) = \(dv.value.trimmedDescription)"
                    }
                    return "var \(name): \(type)"
                }.joined(separator: "\n            "))
            }
        }
        """

        let binding: DeclSyntax = """
        let \(raw: funcName): any AgentTool = \(raw: structName)()
        """

        return [generatedStruct, binding]
    }

    private static func swiftTypeToJSONType(_ type: String) -> String {
        let cleaned = type.replacingOccurrences(of: "?", with: "")
        switch cleaned {
        case "String": return "string"
        case "Int": return "integer"
        case "Double", "Float": return "number"
        case "Bool": return "boolean"
        default:
            if cleaned.contains("Array") || cleaned.hasPrefix("[") { return "array" }
            return "string"
        }
    }

    private static func extractDescription(from funcDecl: FunctionDeclSyntax) -> String {
        // Try to get doc comment
        if let trivia = funcDecl.leadingTrivia.pieces.first(where: {
            if case .docLineComment = $0 { return true }
            return false
        }) {
            if case .docLineComment(let text) = trivia {
                return text.replacingOccurrences(of: "/// ", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return funcDecl.name.text
    }
}

extension String {
    func camelCaseToSnakeCase() -> String {
        var result = ""
        for (i, char) in self.enumerated() {
            if char.isUppercase {
                if i > 0 { result += "_" }
                result += char.lowercased()
            } else {
                result += String(char)
            }
        }
        return result
    }
}

/// The `@StructuredOutput` macro implementation.
///
/// Synthesizes a `jsonSchema` computed property on the annotated struct, generating
/// the JSON Schema from stored properties automatically.
///
/// Input:
/// ```swift
/// @StructuredOutput
/// struct Recipe {
///     let name: String
///     let ingredients: [String]
///     let steps: [String]
/// }
/// ```
///
/// Generated extension:
/// ```swift
/// extension Recipe: StructuredOutput {
///     public static var jsonSchema: JSONSchema {
///         [
///             "type": "object",
///             "properties": [
///                 "name": ["type": "string"],
///                 "ingredients": ["type": "array", "items": ["type": "string"]],
///                 "steps": ["type": "array", "items": ["type": "string"]],
///             ],
///             "required": ["name", "ingredients", "steps"]
///         ]
///     }
/// }
/// ```
public struct StructuredOutputMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw MacroError("@StructuredOutput can only be applied to structs")
        }

        let typeName = structDecl.name.text

        // Collect stored properties (skip computed ones with accessor blocks)
        var properties: [(name: String, schema: String, isOptional: Bool)] = []

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in varDecl.bindings {
                guard binding.accessorBlock == nil else { continue }
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                let name = pattern.identifier.text
                guard let typeAnnotation = binding.typeAnnotation else { continue }
                let typeText = typeAnnotation.type.trimmedDescription
                let (schema, isOptional) = schemaEntry(for: typeText)
                properties.append((name: name, schema: schema, isOptional: isOptional))
            }
        }

        // Build "properties" dict entries
        let propertiesEntries = properties
            .map { "\"\($0.name)\": \($0.schema)" }
            .joined(separator: ",\n                ")

        // Build "required" array (non-optional properties only)
        let requiredNames = properties.filter { !$0.isOptional }.map { "\"\($0.name)\"" }
        let requiredStr: String
        if requiredNames.isEmpty {
            requiredStr = ""
        } else {
            requiredStr = ",\n            \"required\": [\(requiredNames.joined(separator: ", "))]"
        }

        let decl: DeclSyntax = """
        extension \(raw: typeName): StructuredOutput {
            public static var jsonSchema: JSONSchema {
                [
                    "type": "object",
                    "properties": [
                        \(raw: propertiesEntries)
                    ]\(raw: requiredStr)
                ]
            }
        }
        """

        guard let extensionDecl = decl.as(ExtensionDeclSyntax.self) else {
            throw MacroError("@StructuredOutput: failed to build extension declaration")
        }

        return [extensionDecl]
    }

    /// Returns the JSON schema literal string and whether the type is optional.
    private static func schemaEntry(for type: String) -> (schema: String, isOptional: Bool) {
        let trimmed = type.trimmingCharacters(in: .whitespaces)

        // Optional<T> or T?
        if trimmed.hasSuffix("?") {
            let (schema, _) = schemaEntry(for: String(trimmed.dropLast()))
            return (schema, true)
        }
        if trimmed.hasPrefix("Optional<") && trimmed.hasSuffix(">") {
            let inner = String(trimmed.dropFirst("Optional<".count).dropLast())
            let (schema, _) = schemaEntry(for: inner)
            return (schema, true)
        }

        // [T]
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let inner = String(trimmed.dropFirst().dropLast())
            let (itemSchema, _) = schemaEntry(for: inner)
            return (#"["type": "array", "items": \#(itemSchema)]"#, false)
        }

        // Array<T>
        if trimmed.hasPrefix("Array<") && trimmed.hasSuffix(">") {
            let inner = String(trimmed.dropFirst("Array<".count).dropLast())
            let (itemSchema, _) = schemaEntry(for: inner)
            return (#"["type": "array", "items": \#(itemSchema)]"#, false)
        }

        // Primitive types
        switch trimmed {
        case "String":
            return (#"["type": "string"]"#, false)
        case "Int", "Int8", "Int16", "Int32", "Int64",
             "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return (#"["type": "integer"]"#, false)
        case "Double", "Float", "Float32", "Float64":
            return (#"["type": "number"]"#, false)
        case "Bool":
            return (#"["type": "boolean"]"#, false)
        default:
            return (#"["type": "object"]"#, false)
        }
    }
}

struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
struct StrandsAgentsMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ToolMacro.self,
        StructuredOutputMacro.self,
    ]
}
