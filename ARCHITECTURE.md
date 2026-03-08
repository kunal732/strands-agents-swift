# Strands SDK Swift -- Runtime Architecture Design

## Overview

Swift-native port of the Strands Agents SDK. Implements the core Strands concept:
**Agent = Model + Tools + System Prompt + Agent Loop**

Designed for macOS, iOS, tvOS, and server-side Swift. Installs via Swift Package Manager.

---

## Runtime Components

```
User Input
  |
  v
AgentRuntime (public API, lock, lifecycle)
  |
  v
AgentLoop (reasoning cycle)
  |
  +---> ModelRouter ---> ModelProvider (MLXProvider | BedrockProvider | ...)
  |                          |
  |                     StreamEvent sequence
  |                          |
  |       <--- aggregated ContentBlocks + StopReason
  |
  +---> ToolRegistry ---> AgentTool.stream()
  |                          |
  |       <--- ToolResultBlock
  |
  +---> ConversationManager (sliding window, summarizing)
  |
  +---> HookRegistry (before/after model, tool, invocation)
  |
  +---> ObservabilityEngine (OpenTelemetry spans)
  |
  +---> SessionManager (persist/restore)
  |
  v
AgentResult (stopReason, message, metrics)
```

---

## Execution Flow

1. `Agent.run(prompt)` acquires a concurrency lock (prevents reentrant calls)
2. Normalize input into `[ContentBlock]` and append as user message
3. Emit `BeforeInvocationEvent` via hooks
4. Enter **agent loop cycle**:
   a. Emit `BeforeModelCallEvent`
   b. `ModelRouter.route(context)` selects a `ModelProvider`
   c. Call `provider.stream(messages, toolSpecs, systemPrompt)`
   d. Aggregate `ModelStreamEvent`s into `ContentBlock`s (text, toolUse, reasoning)
   e. Emit `AfterModelCallEvent`
   f. Inspect `StopReason`:
      - `.endTurn` / `.maxTokens` / `.contentFiltered` -- exit loop
      - `.toolUse` -- execute tools, append results, continue loop
5. Emit `AfterInvocationEvent`
6. Return `AgentResult`

### Tool Execution (within loop)

1. Extract `ToolUseBlock`s from assistant message
2. For each tool use:
   a. Emit `BeforeToolCallEvent`
   b. Look up tool in `ToolRegistry`
   c. Call `tool.stream(toolUse:context:)` -- yields intermediate events, returns `ToolResultBlock`
   d. Emit `AfterToolCallEvent`
3. Append assistant message + tool result message to conversation
4. Re-enter loop

### Message Append Strategy

Following the TypeScript SDK's deferred-append pattern: assistant messages with tool uses
are only appended to `agent.messages` AFTER tool execution completes. This keeps the
message array always in a valid, reinvokable state.

---

## Module Structure

### StrandsAgents (core library)

All core types, protocols, agent loop, hooks, tool system, conversation management.
No external dependencies beyond Foundation.

```
Sources/StrandsAgents/
  Agent/
    Agent.swift              -- Public Agent class
    AgentResult.swift        -- Result type
    AgentLoop.swift          -- Reasoning loop
  Model/
    ModelProvider.swift       -- Protocol
    ModelRouter.swift         -- Routing abstraction
    StreamEvent.swift         -- Streaming event types
    StreamAggregator.swift   -- Assembles ContentBlocks from stream
  Tool/
    AgentTool.swift          -- Protocol
    ToolRegistry.swift       -- Registration + lookup
    ToolContext.swift         -- Context passed to tools
    FunctionTool.swift       -- Closure-based tool
  Types/
    Message.swift            -- Message, Role
    ContentBlock.swift       -- Text, ToolUse, ToolResult, Image, etc.
    StopReason.swift         -- Model stop reasons
    JSONValue.swift          -- Type-safe JSON
    ToolSpec.swift           -- Tool specification
  ConversationManager/
    ConversationManager.swift          -- Protocol
    SlidingWindowConversationManager.swift
    NullConversationManager.swift
  Hooks/
    HookRegistry.swift       -- Event dispatch
    HookEvents.swift         -- Strongly-typed events
    HookProvider.swift       -- Registration protocol
  Session/
    SessionManager.swift     -- Persist/restore
    SessionStorage.swift     -- Storage protocol
    FileSessionStorage.swift
  Observability/
    ObservabilityEngine.swift     -- OTel integration protocol
    Span.swift                    -- Span abstraction
  Lifecycle/
    AgentTaskManager.swift   -- iOS background task handling
  Errors.swift               -- Error types
```

### StrandsBedrockProvider

AWS Bedrock model provider. Depends on AWS SDK for Swift.

```
Sources/StrandsBedrockProvider/
  BedrockProvider.swift      -- ModelProvider conformance
  BedrockConfig.swift        -- Region, credentials, model ID
  BedrockStreamAdapter.swift -- Convert Bedrock stream to ModelStreamEvent
```

### StrandsMLXProvider

Local inference via MLX Swift. Depends on mlx-swift-lm.

```
Sources/StrandsMLXProvider/
  MLXProvider.swift          -- ModelProvider conformance
  MLXConfig.swift            -- Model path, quantization, device
  MLXStreamAdapter.swift     -- Convert MLX output to ModelStreamEvent
```

---

## Core Protocols and Types

### ModelProvider

```swift
public protocol ModelProvider: Sendable {
    associatedtype Config: Sendable

    var modelId: String? { get }

    func updateConfig(_ config: Config)
    func getConfig() -> Config

    func stream(
        messages: [Message],
        toolSpecs: [ToolSpec]?,
        systemPrompt: String?,
        toolChoice: ToolChoice?
    ) -> AsyncThrowingStream<ModelStreamEvent, Error>
}
```

### ModelRouter

```swift
public protocol ModelRouter: Sendable {
    func route(context: RoutingContext) async throws -> any ModelProvider
}
```

The `RoutingContext` carries: messages, tool specs, system prompt, device capabilities,
and any developer-provided hints. The router returns the provider to use for this call.

### AgentTool

```swift
public protocol AgentTool: Sendable {
    var name: String { get }
    var toolSpec: ToolSpec { get }

    func stream(
        toolUse: ToolUseBlock,
        context: ToolContext
    ) -> AsyncThrowingStream<ToolStreamEvent, Error>
}
```

Tools yield intermediate `ToolStreamEvent`s and terminate with a `ToolResultBlock`.

### HookRegistry

```swift
public final class HookRegistry: @unchecked Sendable {
    func addCallback<E: HookEvent>(_ eventType: E.Type, _ callback: @escaping @Sendable (E) async throws -> Void)
    func invoke<E: HookEvent>(_ event: E) async throws
}
```

### ConversationManager

```swift
public protocol ConversationManager: Sendable {
    func applyManagement(messages: inout [Message]) async
    func reduceContext(messages: inout [Message], error: Error?) async throws
}
```

---

## Streaming Architecture

### Model Stream Events (from providers)

```swift
public enum ModelStreamEvent: Sendable {
    case messageStart(role: Role)
    case contentBlockStart(ContentBlockStart)
    case contentBlockDelta(ContentBlockDelta)
    case contentBlockStop
    case messageStop(stopReason: StopReason)
    case metadata(usage: Usage?, metrics: Metrics?)
}
```

### Stream Aggregation

`StreamAggregator` consumes `ModelStreamEvent`s and produces:
- Intermediate: yields `ContentBlock`s as they complete
- Final: returns `(Message, StopReason, Usage?)`

This mirrors the TypeScript `streamAggregated()` pattern, separating raw provider
streaming from framework-level block assembly.

### Agent-Level Events (yielded to caller)

```swift
public enum AgentStreamEvent: Sendable {
    case textDelta(String)
    case contentBlock(ContentBlock)
    case toolResult(ToolResultBlock)
    case modelMessage(Message)
    case result(AgentResult)
}
```

---

## Content Block Types

```swift
public enum ContentBlock: Sendable, Codable {
    case text(TextBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case image(ImageBlock)
    case document(DocumentBlock)
    case reasoning(ReasoningBlock)
    case citations(CitationsBlock)
    case cachePoint
    case guardContent(GuardContentBlock)
}
```

Each block variant is a simple struct with `Sendable` and `Codable` conformance.

---

## Concurrency Design

### Agent

The `Agent` is a reference type (class) but NOT an actor, because:
- The message array must be directly accessible for conversation management
- Lock semantics are simpler with an `AsyncSemaphore` than actor reentrancy

```swift
public final class Agent: @unchecked Sendable {
    private let lock = AsyncSemaphore(value: 1)
    public private(set) var messages: [Message]
    // ...
}
```

### Tool Execution

Tools run concurrently when the model requests multiple tool uses in a single turn.
Uses a `TaskGroup` to execute tools in parallel, collecting results.

### Streaming

All streaming uses `AsyncThrowingStream` -- the standard Swift pattern for
producer/consumer async sequences. Providers produce events, the agent loop consumes.

---

## Model Routing

### HybridRouter (default implementation)

```swift
public final class HybridRouter: ModelRouter {
    let localProvider: (any ModelProvider)?
    let cloudProvider: any ModelProvider
    let policy: RoutingPolicy

    func route(context: RoutingContext) async throws -> any ModelProvider
}
```

**RoutingPolicy** is a protocol:

```swift
public protocol RoutingPolicy: Sendable {
    func shouldUseLocal(context: RoutingContext) -> Bool
}
```

Built-in policies:
- `AlwaysLocalPolicy` -- always use MLX
- `AlwaysCloudPolicy` -- always use Bedrock
- `LatencySensitivePolicy` -- prefer local for low-latency
- `PrivacySensitivePolicy` -- prefer local for sensitive data
- `FallbackPolicy` -- try local, fall back to cloud on failure

### RoutingContext

```swift
public struct RoutingContext: Sendable {
    let messages: [Message]
    let toolSpecs: [ToolSpec]?
    let systemPrompt: String?
    let hints: RoutingHints
    let deviceCapabilities: DeviceCapabilities
}
```

### Routing Telemetry

Every routing decision is recorded and emitted through the `ObservabilityEngine`:
- Which provider was selected
- Why (policy name, evaluation result)
- Fallback events

---

## Observability

### ObservabilityEngine Protocol

```swift
public protocol ObservabilityEngine: Sendable {
    func startSpan(name: String, attributes: [String: String]) -> SpanContext
    func endSpan(_ context: SpanContext, status: SpanStatus)
    func recordEvent(name: String, attributes: [String: String], spanContext: SpanContext?)
    func recordMetric(name: String, value: Double, unit: String?, attributes: [String: String])
}
```

### Automatic Instrumentation

The agent loop automatically creates spans for:
- `strands.agent.invocation` -- full agent run
- `strands.agent.loop.cycle` -- each loop iteration
- `strands.model.invoke` -- each model call (includes provider, model ID, token counts)
- `strands.tool.invoke` -- each tool call (includes tool name, duration)
- `strands.router.decision` -- each routing decision

### Built-in Engines

- `NoOpObservabilityEngine` -- default, zero overhead
- `OTelObservabilityEngine` -- OpenTelemetry export (Datadog, AWS OTEL, generic)
- `PrintObservabilityEngine` -- debug logging

### Content Redaction

```swift
public protocol ContentRedactor: Sendable {
    func redact(_ content: String) -> String
}
```

Applied before recording prompt/response content in spans.

---

## iOS Lifecycle Integration

### AgentTaskManager

```swift
public actor AgentTaskManager {
    func beginTask(_ task: AgentTask) async -> AgentTaskHandle
    func serializeState(for handle: AgentTaskHandle) async throws -> Data
    func restoreTask(from data: Data) async throws -> AgentTaskHandle
}
```

### Background Execution Pattern

1. Agent starts task in foreground using MLX
2. If app enters background:
   a. Serialize current agent state (messages, tool results so far, loop position)
   b. If task is critical, escalate remaining work to Bedrock via background URL session
   c. On completion, deliver local notification
3. When app returns to foreground:
   a. Check for completed background results
   b. Restore agent state and deliver result

### AgentTask

```swift
public struct AgentTask: Sendable {
    let id: UUID
    let prompt: String
    let priority: TaskPriority
    let backgroundPolicy: BackgroundPolicy

    enum BackgroundPolicy: Sendable {
        case cancelOnBackground
        case escalateToCloud
        case serializeAndResume
    }
}
```

---

## Session Persistence

### SessionManager

```swift
public final class SessionManager: HookProvider {
    let storage: SessionStorage

    func save(agent: Agent) async throws
    func restore(agent: Agent) async throws -> Bool
}
```

### SessionStorage Protocol

```swift
public protocol SessionStorage: Sendable {
    func save(sessionId: String, data: Data) async throws
    func load(sessionId: String) async throws -> Data?
    func delete(sessionId: String) async throws
    func list() async throws -> [String]
}
```

Built-in: `FileSessionStorage`, extensible to S3, CloudKit, etc.

---

## Hook Events

```swift
// Lifecycle
public struct AgentInitializedEvent: HookEvent { ... }
public struct BeforeInvocationEvent: HookEvent { ... }
public struct AfterInvocationEvent: HookEvent { ... }
public struct MessageAddedEvent: HookEvent { ... }

// Model
public struct BeforeModelCallEvent: HookEvent { ... }
public struct AfterModelCallEvent: HookEvent { ... }

// Tool
public struct BeforeToolCallEvent: HookEvent { ... }
public struct AfterToolCallEvent: HookEvent { ... }

// Routing
public struct RoutingDecisionEvent: HookEvent { ... }
```

Each event carries relevant context and is dispatched through `HookRegistry`.

---

## Error Types

```swift
public enum StrandsError: Error, Sendable {
    case modelThrottled(retryAfter: TimeInterval?)
    case maxTokensReached(partialMessage: Message)
    case contextWindowOverflow
    case toolNotFound(name: String)
    case toolExecutionFailed(name: String, underlying: Error)
    case invalidToolInput(name: String, reason: String)
    case contentFiltered(reason: String?)
    case serializationFailed(underlying: Error)
    case providerError(underlying: Error)
    case routingFailed(reason: String)
    case cancelled
}
```

---

## Retry Strategy

```swift
public struct RetryStrategy: Sendable {
    var maxAttempts: Int = 6
    var initialDelay: TimeInterval = 4.0
    var maxDelay: TimeInterval = 240.0
    var backoffMultiplier: Double = 2.0

    func execute<T>(_ operation: () async throws -> T) async throws -> T
}
```

Applied around model calls. Retries on `StrandsError.modelThrottled`.

---

## Package Dependencies

### StrandsAgents (core)
- Foundation only (zero external dependencies)

### StrandsBedrockProvider
- StrandsAgents
- aws-sdk-swift (BedrockRuntime)

### StrandsMLXProvider
- StrandsAgents
- mlx-swift-lm

### StrandsOTelObservability (optional)
- StrandsAgents
- swift-otel or opentelemetry-swift

---

## Developer API

```swift
// Minimal
let agent = Agent(model: BedrockProvider(modelId: "anthropic.claude-sonnet-4-20250514"))
let result = try await agent.run("Hello!")
print(result)

// With tools
let agent = Agent(
    model: BedrockProvider(modelId: "anthropic.claude-sonnet-4-20250514"),
    tools: [CalculatorTool(), WeatherTool()],
    systemPrompt: "You are a helpful assistant."
)
let result = try await agent.run("What is 42 * 17?")

// Streaming
for try await event in agent.stream("Tell me a story") {
    switch event {
    case .textDelta(let text): print(text, terminator: "")
    case .result(let result): print("\nDone: \(result.stopReason)")
    default: break
    }
}

// Hybrid routing
let agent = Agent(
    router: HybridRouter(
        local: MLXProvider(modelPath: "mlx-community/Llama-3.2-3B"),
        cloud: BedrockProvider(modelId: "anthropic.claude-sonnet-4-20250514"),
        policy: LatencySensitivePolicy()
    ),
    tools: [SearchTool()],
    observability: OTelObservabilityEngine(endpoint: "https://otel.example.com")
)
let result = try await agent.run("Summarize this email")
```

---

## Platform Availability

| Feature | macOS | iOS | tvOS | Server |
|---------|-------|-----|------|--------|
| Agent core | yes | yes | yes | yes |
| Bedrock provider | yes | yes | yes | yes |
| MLX provider | yes | no | no | no |
| AgentTaskManager | yes | yes | yes | no |
| File session storage | yes | yes | yes | yes |
| OTel observability | yes | yes | yes | yes |

MLX is Apple Silicon only (macOS). On iOS/tvOS the router automatically
falls back to cloud providers.

---

## Implementation Stages

### Stage 1: Foundation
- Core types (Message, ContentBlock, ToolSpec, StopReason, JSONValue)
- ModelProvider protocol
- AgentTool protocol + ToolRegistry
- AgentLoop
- Agent (basic run + stream)
- HookRegistry + hook events
- ConversationManager (sliding window)
- Error types + RetryStrategy

### Stage 2: Providers + Tools
- BedrockProvider
- MLXProvider
- FunctionTool (closure-based)
- Tool context injection

### Stage 3: Routing + Observability + Lifecycle
- ModelRouter + HybridRouter + policies
- ObservabilityEngine + OTel integration
- AgentTaskManager (iOS lifecycle)
- SessionManager + FileSessionStorage

### Stage 4: Polish
- Developer API refinement
- Example apps
- Integration tests
- Documentation
