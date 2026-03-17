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
@attached(peer, names: arbitrary)
public macro Tool() = #externalMacro(module: "StrandsAgentsMacros", type: "ToolMacro")
