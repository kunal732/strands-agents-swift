# Claude Session Brief

## 1. Session Metadata
| Field | Value |
|---|---|
| Project | strands-sdk-swift |
| Date | 2026-03-24 |
| Session ID | 20260324-implem |
| Participants | User (Kunal Batra), Claude |
| Source | Claude conversation transcript |
| Location | /Users/kunal.batra/Documents/code/datadog/strands/sdk-swift |

---

## 2. TL;DR
Massive session spanning the full lifecycle of the Strands Agents Swift SDK: implemented `@StructuredOutput` macro, built a 16-page documentation website at communitystrands.com, created 12 sample programs, fixed OTel span hierarchy for Datadog LLM Observability, implemented hybrid routing with real device signals, built a DesktopAssistant menu bar app with MCP desktop control, redesigned multi-agent examples as proper macOS apps, and designed a new macro-free tool definition API where the model infers parameter names and tool names from descriptions. Key open item: implement the new `Tool(function, "description")` API with model-inferred schemas and separate the macro into an opt-in module.

---

## 3. Initial Objective
- Implement `@StructuredOutput` macro for the Strands Agents Swift SDK
- Create documentation website similar to strandsagents.com
- Ensure OTel telemetry works with Datadog LLM Observability

---

## 4. Key Discussion Points

Theme flow: `@StructuredOutput macro` → `Documentation website` → `Multi-agent reframing for Apple` → `OTel/Datadog integration` → `Hybrid routing implementation` → `Blog + communitystrands.com` → `Sample programs` → `DesktopAssistant menu bar app` → `MCP desktop control` → `Voice agents (blocked)` → `Tool definition API redesign`

### 4.1 @StructuredOutput Macro
- Implemented `StructuredOutputMacro: ExtensionMacro` in ToolMacro.swift
- Generates `jsonSchema` from stored properties automatically
- Added macro declaration and 3 tests (87 total tests passing)

### 4.2 Documentation Website (communitystrands.com)
- Built 16-page static HTML/CSS/JS docs site with dark theme, syntax highlighting, sidebar nav
- Reframed multi-agent docs for on-device Apple ecosystem (not server-side)
- Added animated SVG pipeline diagrams for Graph orchestrator
- Created blog system loading markdown from GitHub raw URLs
- Set up communitystrands.com domain with GitHub Pages
- Added Datadog RUM instrumentation to all pages

### 4.3 OTel Observability for Datadog
- Fixed span hierarchy: added `startChildSpan(name:attributes:parentId:)` to protocol
- Added `OTelObservabilityEngine.datadog()` convenience factory
- Documented API key safety (Lambda proxy, DDOT Collector patterns)
- Added endpoint parameter for custom OTLP destinations

### 4.4 Hybrid Routing
- Fixed `DeviceCapabilities.current`: real available memory via vm_statistics64, arm64 check for Neural Engine
- Added `agent.routingHints` property for per-call hints
- Added `lastInferenceLatencyMs` and `estimatedPromptTokens` to RoutingContext
- Rewrote `LatencySensitivePolicy` and `FallbackPolicy` with real signals
- Documented all routing policies, hints, and custom router patterns

### 4.5 Sample Programs (12 total)
- 01-SimpleLocalAgent through 12-MCPDesktopControl
- Fixed all API mismatches (MultiAgentResult, config initializers, MCP provider)
- Added as executable targets in Package.swift
- Verified Samples 02, 06, 07 run successfully with Bedrock

### 4.6 DesktopAssistant Menu Bar App
- NSStatusItem + NSPopover with Cmd+Shift+A global hotkey
- MCP tools from automation-mcp (18 tools) + native CGDisplayCreateImage screenshot
- Text agent with Claude Sonnet on Bedrock
- Escape key cancellation via Task.cancel
- Fixed popover stealing focus (NSApp.hide + 1s delay before automation)
- Verified: agent opens TextEdit via Spotlight, types text, takes screenshots

### 4.7 Voice Agents (Blocked)
- Nova Sonic: AWS SDK for Swift uses URLSession which can't do HTTP/2 bidi streams
- Local MLX: AVAudioEngine deadlocks in menu bar apps without proper app bundle
- Marked as "Coming Soon" in README and docs

### 4.8 WritingAssistant + PersonalAssistant Example Apps
- Full macOS apps with NavigationSplitView, sidebars, toolbars
- Required xcodegen + hand-written project.pbxproj for proper .app bundles
- SwiftPM executable targets cannot produce .app bundles (fundamental limitation)

### 4.9 Tool Definition API Redesign
- Explored multiple approaches to simplify tool definitions without macros
- Designed model-inferred parameter naming: one inference call at startup
- Final design: `Tool(function, "description")` with optional `name:` override
- Schema auto-discovered: model names both the tool and its parameters
- Works fully offline with local MLX models

---

## 5. Decisions and Rationale

### Decision 1: @StructuredOutput as ExtensionMacro
- **Decision:** Implemented as ExtensionMacro generating a protocol extension with jsonSchema
- **Why:** Matches the @Model/Model pattern from SwiftData; avoids naming conflicts
- **Alternatives:** PeerMacro, MemberMacro
- **Tradeoffs:** Extension macros are cleaner but slightly more complex to implement
- **Confidence:** High
- **Evidence:** > "The attribute name @StructuredOutput coexists with the StructuredOutput protocol"

### Decision 2: Reframe multi-agent for on-device Apple context
- **Decision:** Rewrote all multi-agent docs to focus on iOS/macOS single-process patterns
- **Why:** Server-side framing (microservices, lambdas) doesn't fit Swift which runs on devices
- **Alternatives:** Keep generic server-side framing
- **Tradeoffs:** Less applicable to server-side Swift users; much more relevant to actual audience
- **Confidence:** High
- **Evidence:** > "its just confusing... that's not the case for an agent created in swift most likely"

### Decision 3: communitystrands.com as separate repo from SDK
- **Decision:** Umbrella site in kunal732/communitystrands, SDK docs in swift/ subfolder
- **Why:** Supports future Kotlin/Rust ports under one domain; blog shared across languages
- **Alternatives:** Docs in SDK repo, subdomain per language
- **Tradeoffs:** Need to sync docs manually or via GitHub Action
- **Confidence:** High
- **Evidence:** > "i like communitystrands.com since i can also introduce more languages"

### Decision 4: Fix OTel span hierarchy with explicit parent IDs
- **Decision:** Added `startChildSpan(parentId:)` to ObservabilityEngine protocol
- **Why:** Spans were all root spans because startSpan never set a parent
- **Alternatives:** Implicit context propagation via OTel context manager
- **Tradeoffs:** Explicit is more work but correct for concurrent tool calls
- **Confidence:** High
- **Evidence:** > "Spans were all emitted as root spans because startSpan() never set a parent"

### Decision 5: Voice agents marked Coming Soon
- **Decision:** Remove voice/bidi from functional features, document as Coming Soon
- **Why:** Nova Sonic needs HTTP/2 bidi (not in AWS SDK for Swift); MLX audio crashes in menu bar apps
- **Alternatives:** Keep trying to fix audio session issues
- **Tradeoffs:** Honest about what works vs. shipping broken features
- **Confidence:** High
- **Evidence:** > "the bidi streaming is not working... lets remove it as functionally something that can be used"

### Decision 6: Apache 2.0 license (matching upstream)
- **Decision:** Relicensed from MIT to Apache 2.0, added NOTICE file
- **Why:** Required for derivative works of the Apache 2.0 upstream Strands SDK
- **Alternatives:** Keep MIT (legally incorrect)
- **Tradeoffs:** None; Apache 2.0 is equally permissive
- **Confidence:** High
- **Evidence:** > "your repo uses MIT, not Apache 2.0... Since your Swift SDK is a derivative work"

### Decision 7: Model-inferred tool parameter naming
- **Decision:** Design a Tool API where the model infers parameter names and tool names from descriptions
- **Why:** Swift erases function parameter labels at runtime; macro requires trust prompt; all other approaches require repeating param names
- **Alternatives:** @Tool macro, FunctionTool with params tuple, Codable input structs, ToolDefinition protocol
- **Tradeoffs:** Extra inference call at startup (cached); non-deterministic param names (mitigated by caching)
- **Confidence:** Med (designed but not yet implemented)
- **Evidence:** > "yes this feels great" / "perfect, then for this design where we wrap a function"

### Decision 8: Separate macro into opt-in module
- **Decision:** Split StrandsAgentsMacros out of StrandsAgents so users who don't use @Tool never see trust prompt
- **Why:** Xcode trust prompt for macros is high friction and "will kill the project"
- **Alternatives:** Keep bundled (current), remove macros entirely
- **Tradeoffs:** Users who want @Tool add an extra import; users who don't want macros never see the prompt
- **Confidence:** High
- **Evidence:** > "asking a user to trust a macro they just downloaded without knowing what its doing is too much friction"

---

## 6. Outputs Produced

### SDK Code
- `Sources/StrandsAgentsMacros/ToolMacro.swift` -- StructuredOutputMacro implementation
- `Sources/StrandsAgents/Tool/ToolMacroDeclaration.swift` -- @StructuredOutput and @Tool (peer names fix)
- `Sources/StrandsAgents/Tool/Tool.swift` -- New Tool type with auto-discovery and model inference design
- `Sources/StrandsAgents/Tool/FunctionTool.swift` -- Added ToolParam, ToolArgs, simplified initializer
- `Sources/StrandsAgents/Observability/ObservabilityEngine.swift` -- startChildSpan protocol addition
- `Sources/StrandsOTelObservability/OTelObservabilityEngine.swift` -- .datadog() factory, OTLP HTTP exporter
- `Sources/StrandsAgents/Model/ModelRouter.swift` -- Full rewrite: real DeviceCapabilities, LatencySensitivePolicy, FallbackPolicy
- `Sources/StrandsAgents/Agent/AgentLoop.swift` -- Parent span threading, routing hints, lastLatencyMs
- `Sources/StrandsAgents/Agent/Agent.swift` -- routingHints property
- `Sources/StrandsAgents/Tool/MCPToolProvider.swift` -- Fixed stdio response reading (was using availableData)

### Documentation Website (communitystrands repo)
- 16 HTML pages: index, getting-started, agents, tools, structured-output, streaming, local-inference, multi-agent (4 pages), voice-agents, providers, observability, session, modules
- `styles.css` -- Dark theme with Swift orange accent
- `nav.js` -- Sidebar, header, TOC generation, hashchange handling
- `blog/` -- Blog system with index.json + markdown posts

### Example Apps
- `Examples/DesktopAssistant/` -- 4 files: menu bar app with MCP desktop control
- `Examples/WritingAssistant/` -- 6 files + xcodeproj: multi-agent graph demo
- `Examples/PersonalAssistant/` -- 6 files + xcodeproj: multi-agent swarm demo

### Samples (12)
- `Samples/01-SimpleLocalAgent` through `Samples/12-MCPDesktopControl`

### Infrastructure
- `NOTICE` file -- Apache 2.0 attribution to AWS
- `LICENSE` -- Relicensed to Apache 2.0
- `blog/` directory with index.json and first post
- `.gitignore` -- exceptions for xcodeproj files

---

## 7. Problems / Frictions Encountered
- `@Tool` macro with `names: arbitrary` fails at global scope in Xcode app targets; fixed with `names: prefixed(_GeneratedTool_), overloaded`
- `@Tool` on zero-parameter functions causes redeclaration conflict (let binding same name as func); workaround: add a default parameter
- `@Tool` macro required array generated broken string literal (`".string("text")"` instead of `.string("text")`)
- SwiftPM executable targets cannot produce macOS .app bundles; windows never appear when run from Xcode
- AVAudioEngine deadlocks on @MainActor in menu bar apps; crashes when NSApp.setActivationPolicy is .accessory
- Nova Sonic bidi streaming fails because AWS SDK for Swift uses URLSession (regular HTTP POST) instead of HTTP/2 bidirectional stream
- MCPToolProvider used `availableData` which returns empty data if server hasn't responded (race condition)
- MCP server's screenshot tool has base64 encoding bug; replaced with native CGDisplayCreateImage
- Popover steals focus from Spotlight during desktop automation; fixed with NSApp.hide + 1s delay
- xcodegen generates xcodeproj with package resolved but products not linked to target
- `.gitignore` excluded all `.xcodeproj/` preventing example projects from being committed
- `mlx-swift-lm` package URL trailing slash caused Xcode resolution failure

---

## 8. Open Questions / Risks
- [ ] Implement the new `Tool(function, "description")` API with model-inferred schemas
- [ ] Implement the macro module separation (StrandsAgents without macros, StrandsAgentsMacros opt-in)
- [ ] Nova Sonic bidi streaming blocked until AWS SDK for Swift adds HTTP/2 bidi support or we implement it directly via swift-nio-http2
- [ ] Local MLX voice blocked on AVAudioEngine in menu bar/CLI apps (needs proper .app bundle)
- [ ] Tool inference caching strategy: where to persist cached schemas (UserDefaults, file, bundle?)
- [ ] Non-determinism of model-inferred param names across sessions (cache mitigates but doesn't eliminate)
- [ ] communitystrands.com domain trademark risk with AWS/Strands branding (user advised to get confirmation)
- [ ] DesktopAssistant MCP tools require Accessibility permissions granted to the bun process specifically

---

## 9. Next Steps
- [ ] Implement `Tool(function, "description")` with model inference for param names and tool names
- [ ] Separate macro into opt-in `StrandsAgentsMacros` module
- [ ] Add tool schema caching (disk persistence for inferred schemas)
- [ ] Test WritingAssistant and PersonalAssistant apps end-to-end from clean clone
- [ ] Investigate swift-nio-http2 for Nova Sonic bidi streaming (Option 3 from plan)
- [ ] Add clear trust prompt documentation to README explaining what @Tool does
- [ ] Sync communitystrands/swift/ docs with latest changes

---

## 10. Meta Insights
- The biggest design tension in the SDK is tool definitions: Swift's runtime limitations (no parameter label reflection) force either macros (trust friction) or manual metadata (developer friction). The model-inference approach is a novel solution that leverages the agent's own model to bridge the gap.
- SwiftPM and macOS GUI apps are fundamentally incompatible for windowed apps. Any example with a window needs a proper .xcodeproj with Info.plist containing NSPrincipalClass. This is a platform limitation, not a framework bug.
- The session evolved from "port the SDK" to "rethink how tools work in Swift" -- the model-inferred schema design is original to this SDK and doesn't exist in the Python or TypeScript versions.
- Honest documentation (marking voice as Coming Soon, documenting API key safety risks, explaining Bedrock HTTP/2 limitation) builds more trust than shipping broken features.
