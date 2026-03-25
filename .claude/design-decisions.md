# Design Decisions & Anti-Regression Guide
**Updated:** 2026-03-24
**Project:** /Users/kunal.batra/Documents/code/datadog/strands/sdk-swift

---

## CURRENT APPROACH

### Tool Definition API (NOT YET IMPLEMENTED)

The primary tool definition API will be `Tool(function, "description")` where:

1. **User writes a normal Swift function** with typed parameters
2. **User wraps it**: `Tool(fetchWeather, "Get the current weather for a city.")`
3. **Model infers** the tool name AND parameter names via one batched inference call at agent startup
4. **Framework caches** the inferred schema to disk; subsequent runs skip inference entirely
5. **Positional mapping**: model's JSON args are mapped to function parameters by the order they were inferred
6. **Optional name override**: `Tool(fetchWeather, "Get weather.", name: "weather_api")`

The API supports:
- Function references: `Tool(fetchWeather, "description")`
- Inline closures: `Tool("description") { (city: String, unit: String) in ... }`
- Zero-param functions: `Tool("description") { Date().description }`
- Any return type conforming to CustomStringConvertible

Generic overloads handle 0, 1, 2, 3 parameter functions with `JSONToolParam` constraints (String, Int, Double, Bool).

### Macro Module Separation (NOT YET IMPLEMENTED)

- `StrandsAgents` core target will NOT depend on `StrandsAgentsMacros`
- New library product exposes `@Tool` and `@StructuredOutput` as opt-in
- Users who want macros explicitly add the macro product to their target
- Users who only use `Tool()` or `FunctionTool()` never see the Xcode trust prompt
- The macro declaration file (`ToolMacroDeclaration.swift`) moves to the new target

### Existing Tool APIs (KEEP, do not remove)

- `FunctionTool(name:description:inputSchema:handler:)` -- full-control raw API
- `FunctionTool(name:description:params:handler:)` -- ToolParam-based API with ToolArgs
- `AgentTool` protocol -- manual conformance for complex tools
- `@Tool` macro -- moves to opt-in module but still supported

---

## REJECTED APPROACHES -- DO NOT SUGGEST THESE

- [REJECTED] **Codable input struct as schema** (`struct GetWeather: Codable { let city: String }`): Still requires a separate struct AND a function. More boilerplate, not less. User said "this still feels complex."

- [REJECTED] **ToolDefinition protocol** (`struct GetWeather: ToolDefinition { var city = ""; var result: String { ... } }`): Requires default values on all properties, computed `result` property, `static let description`. User said "this still feels complex."

- [REJECTED] **Labeled tuple function convention** (`func getWeather(_ p: (city: String, days: Int)) -> String`): Changes how users write functions. Tuple labels erased at generic level anyway.

- [REJECTED] **`params:` tuple alongside function reference** (`Tool("name", "desc", params: ("city", "unit"), code: fetchWeather)`): User explicitly rejected separate params. "I don't want the params section."

- [REJECTED] **`args.string("city")` dry-run recording** (`Tool("name", "desc") { args in args.string("city") }`): User said "these look like they are just another way to write a function with a comment in it."

- [REJECTED] **`ToolParam` array** (`.string("city"), .int("days")`): Too verbose.

- [REJECTED] **Manual JSON inputSchema**: Hard to read, error-prone, terrible DX.

- [REJECTED] **Schema-less tool calling** (empty schema, description carries all semantics): Unreliable with weaker models.

- [REJECTED] **Convention of `code: getTemperature(city: String, unit: String)`**: Not valid Swift syntax.

- [REJECTED] **Keeping macros bundled in StrandsAgents**: Trust prompt for ALL users. "will kill the project."

- [REJECTED] **Removing macros entirely**: @Tool is the right design. Problem is trust UX, not the macro.

- [REJECTED] **Python-style runtime reflection of function parameter names**: Swift doesn't support this. Language constraint.

- [REJECTED] **Using different tool examples in different README sections**: Always use `wordCount` as canonical example throughout.

- [REJECTED] **Recommending manual `AgentTool` as the default path**: Macro or `Tool()` should be primary.

---

## KEY DESIGN DECISIONS

1. **Swift erases function parameter labels from function values at runtime.** The macro reads labels at compile time. The model-inference approach has the LLM name the parameters instead.

2. **The model infers both tool name AND parameter names from the description.** One batched inference call at startup for all tools. Cached to disk. Works offline with local MLX models.

3. **Positional mapping for function arguments.** Framework maps model JSON args to Swift function params by position.

4. **The macro module is opt-in, not bundled.** `StrandsAgents` has no macro dependency. Users who want `@Tool` add the macro product separately.

5. **Multiple tool definition APIs coexist.** `Tool(func, "desc")` is primary simple API. `@Tool` macro is zero-boilerplate (opt-in). `FunctionTool` is full-control escape hatch.

6. **Tool schema caching is transparent.** Check for cache at startup. If present, use. If not, infer and cache. Ships with app bundle for end users.

7. **For local MLX models, inference runs on-device.** No internet needed at any point.

8. **`wordCount` is the canonical tool example** used throughout README and docs.

9. **Voice agents are Coming Soon.** Nova Sonic blocked on HTTP/2 bidi. Local MLX blocked on AVAudioEngine in menu bar apps.

10. **On-device Apple ecosystem framing for multi-agent.** Not server-side microservices. Agents run in the same process on the same device.

---

## HARD CONSTRAINTS

- Swift cannot reflect on function parameter labels at runtime
- Swift cannot get a function's name from its value
- Xcode shows trust prompt for ANY package containing Swift macros
- SwiftPM executable targets cannot produce macOS .app bundles
- AVAudioEngine deadlocks on @MainActor in menu bar apps without a proper app bundle
- AWS SDK for Swift uses URLSession which cannot do HTTP/2 bidirectional streaming
- `@Tool` macro with `names: arbitrary` fails at global scope in Xcode app targets
- `@Tool` on zero-parameter functions causes redeclaration conflict

---

## EXPLICIT DO-NOTs

- **DO NOT** bundle `StrandsAgentsMacros` as a dependency of `StrandsAgents`
- **DO NOT** require users to type parameter names as strings when defining tools
- **DO NOT** require users to write JSON schemas manually
- **DO NOT** require a separate input struct/type for tool parameters
- **DO NOT** change how users write Swift functions to accommodate the framework
- **DO NOT** mark voice agents / bidi streaming as a working feature
- **DO NOT** use `names: arbitrary` in macro declarations
- **DO NOT** use `availableData` for reading MCP server responses
- **DO NOT** embed Datadog API keys in shipped app binaries
- **DO NOT** use different tool examples across README sections (always `wordCount`)
- **DO NOT** recommend manual `AgentTool` as the default path
- **DO NOT** use em dashes in any text output (use rephrased punctuation instead)
- **DO NOT** claim "feature parity" with Python/TypeScript SDKs

---

## CURRENT STATE

### Implemented and Working
- `FunctionTool` with `ToolParam`/`ToolArgs` simplified API
- `Tool` type with dry-run recording approach (ToolInput) -- intermediate step, will be replaced
- `@Tool` macro (bundled in StrandsAgents -- needs separation)
- `@StructuredOutput` macro
- OTel span hierarchy with parent-child linking
- `OTelObservabilityEngine.datadog()` factory
- Hybrid routing with real device signals
- 12 sample programs
- DesktopAssistant menu bar app with MCP tools
- WritingAssistant and PersonalAssistant example apps
- communitystrands.com documentation website
- Blog system
- Apache 2.0 license

### NOT YET Implemented (Agreed Design)
- [ ] `Tool(function, "description")` with model-inferred param/tool names
- [ ] Macro module separation (StrandsAgents without macros)
- [ ] Tool schema caching to disk
- [ ] Batched inference call for all tools at agent startup
- [ ] Optional `name:` override parameter on Tool

### Blocked
- [ ] Nova Sonic voice (HTTP/2 bidi not in AWS SDK for Swift)
- [ ] Local MLX voice (AVAudioEngine in menu bar apps)
