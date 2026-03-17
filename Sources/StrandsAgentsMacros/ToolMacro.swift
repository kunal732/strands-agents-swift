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
                required.append("\".string(\"\(paramName)\")\"")
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

struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
struct StrandsAgentsMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ToolMacro.self,
    ]
}
