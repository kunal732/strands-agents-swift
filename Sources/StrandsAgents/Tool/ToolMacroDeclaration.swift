/// Transforms a Swift function into an agent tool.
///
/// The macro generates:
/// - A tool name (camelCase to snake_case)
/// - A JSON schema from the function signature
/// - A description from the doc comment
/// - An `AgentTool`-conforming wrapper struct
/// - A binding that can be passed to `Agent(tools: [...])`
///
/// ```swift
/// /// Get the current weather for a city
/// @Tool
/// func getWeather(city: String, unit: String = "fahrenheit") async throws -> String {
///     return "72F, sunny in \(city)"
/// }
///
/// // Use it:
/// let agent = Agent(model: provider, tools: [getWeather])
/// ```
///
/// Parameters become JSON schema properties. Types map automatically:
/// - `String` -> `"string"`
/// - `Int` -> `"integer"`
/// - `Double` -> `"number"`
/// - `Bool` -> `"boolean"`
///
/// Parameters with default values become optional in the schema.
/// The doc comment becomes the tool description.
@attached(peer, names: prefixed(_GeneratedTool_), overloaded)
public macro Tool() = #externalMacro(module: "StrandsAgentsMacros", type: "ToolMacro")

/// Synthesizes `StructuredOutput` conformance for a struct.
///
/// Automatically generates a `jsonSchema` computed property from the struct's
/// stored properties, eliminating hand-written JSON schema boilerplate.
///
/// ```swift
/// @StructuredOutput
/// struct Recipe {
///     let name: String
///     let ingredients: [String]
///     let steps: [String]
///     let note: String?   // optional -- omitted from "required"
/// }
///
/// // Struct now conforms to StructuredOutput without any manual jsonSchema:
/// let recipe: Recipe = try await agent.runStructured("Give me a pasta recipe")
/// ```
///
/// Supported type mappings:
/// - `String` -> `"string"`
/// - `Int` / integer variants -> `"integer"`
/// - `Double` / `Float` -> `"number"`
/// - `Bool` -> `"boolean"`
/// - `[T]` / `Array<T>` -> `"array"` with nested item schema
/// - `T?` / `Optional<T>` -> same schema as `T`, omitted from `"required"`
///
/// The attribute name `@StructuredOutput` coexists with the `StructuredOutput`
/// protocol -- the same pattern SwiftData uses with `@Model`/`Model`.
@attached(extension, conformances: StructuredOutput, names: named(jsonSchema))
public macro StructuredOutput() = #externalMacro(module: "StrandsAgentsMacros", type: "StructuredOutputMacro")
