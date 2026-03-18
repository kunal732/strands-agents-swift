# Introducing the Strands Agents Swift SDK

AWS released the [Strands Agents SDK](https://github.com/strands-agents) earlier this year with official support for Python and TypeScript. The framework is genuinely well-designed: a clean agent loop, composable tools, structured output, multi-agent coordination, and first-class OpenTelemetry support. It is the first agent framework from a major cloud provider that feels like it was built by people who actually write production agents.

There was one problem. No Swift.

If you are building an iOS app, a macOS utility, or anything that runs on Apple hardware, you were either wrapping a Python process, calling a REST API, or reaching for a different framework entirely. None of those are good options when the device in your user's pocket has a Neural Engine that can run a capable language model locally in milliseconds.

So we built a Swift port.

## What it is

The Strands Agents Swift SDK is a community implementation of the Strands framework for Apple platforms. It targets full feature parity with the Python and TypeScript SDKs while adding capabilities that only make sense on Apple hardware.

The core is a Swift 6 package that runs on macOS 14+, iOS 17+, and tvOS 17+. It has no runtime dependencies beyond Foundation for the core module. Cloud provider modules bring in their respective SDKs only if you add them.

## What works today

**Tools via the `@Tool` macro.** Annotate any Swift function and the compiler generates the JSON schema, tool name, and `AgentTool` conformance automatically. The function is still callable directly as regular Swift.

```swift
/// Search the web and return a summary of the results.
@Tool
func searchWeb(query: String, maxResults: Int = 5) async throws -> String {
    // your implementation
}

let agent = Agent(model: provider, tools: [searchWeb])
```

**Structured output via `@StructuredOutput`.** Annotate a `Codable` struct and the macro synthesizes the `jsonSchema` from stored properties. Optional fields are automatically omitted from `required`. The agent uses a hidden tool to force the model to produce exactly that structure.

```swift
@StructuredOutput
struct Recipe {
    let name: String
    let ingredients: [String]
    let steps: [String]
    let note: String?
}

let recipe: Recipe = try await agent.runStructured("Give me a pasta recipe")
```

**On-device inference with MLX.** Run quantized language models entirely on Apple Silicon. No network, no API keys, no data leaving the device. Models download from HuggingFace and cache locally on first run. Qwen3-8B-4bit produces reliable tool calling and fits comfortably on a MacBook Pro.

```swift
import StrandsMLXProvider

let agent = Agent(model: MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit"))
```

**Hybrid routing.** A `HybridRouter` sits between your agent and its models and picks local or cloud on every request based on a configurable policy. The policies read real device signals: available RAM (via `vm_statistics64`), thermal state (via `ProcessInfo`), whether the device is on battery, the latency of the previous inference, and estimated prompt token count. You can also pass per-call hints or write a custom policy.

```swift
let agent = Agent(
    router: HybridRouter(
        local: MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit"),
        cloud: BedrockProvider(...),
        policy: LatencySensitivePolicy()
    )
)

// Hint for one call
agent.routingHints = RoutingHints(privacySensitive: true)
let result = try await agent.run("Summarize my health records")
```

**OpenTelemetry tracing with GenAI semantic conventions.** Every agent run produces a connected trace tree: `invoke_agent` > `execute_event_loop_cycle` > `chat` + `execute_tool`. All spans are properly linked with parent-child relationships. Token counts, tool status, finish reason, and latency are emitted as span events using the standard `gen_ai.*` attribute names. Point it at Datadog LLM Observability with four lines of configuration.

**Multi-agent.** Graph (DAG-based parallel pipelines), Swarm (dynamic handoffs between specialists), and A2A (HTTP-based cross-process communication). All three run in a single process on a single device -- the right mental model for an iOS or macOS app. A2A is the bridge to backend agents when you need server compute.

**Cloud providers.** AWS Bedrock (ConverseStream), Anthropic, OpenAI, and Google Gemini are all supported as separate modules. None of them are imported unless you add them as dependencies.

## What is different about a Swift agent SDK

The Python and TypeScript SDKs assume a server. The Swift SDK assumes a device. That shapes several design decisions:

**Privacy is a first-class signal.** On a phone or Mac, your agent might be reading Calendar events, HealthKit data, messages, or documents that should never leave the device. The `privacySensitive` routing hint exists precisely for this -- it forces local inference regardless of what the policy would otherwise decide.

**Hardware state matters.** A server's CPU is always available and always plugged in. A phone is not. The routing system reads thermal state, available RAM, and power source. A `FallbackPolicy` configured with a `slowInferenceThresholdMs` will automatically fall back to cloud if local inference is struggling -- no code changes needed.

**The Neural Engine is real.** Apple Silicon's unified memory architecture makes local inference genuinely competitive for many tasks. A Qwen3-8B model on an M2 Mac produces results fast enough for interactive use. This is not a gimmick; it is a meaningful capability that does not exist on any other platform the Strands SDK targets.

## What is coming

The SDK is at feature parity with the Python and TypeScript SDKs for agent fundamentals. The areas we are actively working on:

- **Kotlin port.** Same design, same feature set, targeting Android and JVM.
- **Better routing signals.** Prompt complexity classification, not just character count. Cost tracking across a session.
- **Voice agent improvements.** The bidirectional streaming pipeline exists; we are working on tighter integration with AVFoundation for cleaner iOS audio I/O.
- **MCP server tooling.** The client is implemented; we want to make it easier to run an MCP server directly from a Swift process.

## Getting started

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kunal732/strands-agents-swift.git", branch: "main")
]
```

Then read the [Getting Started guide](/docs/getting-started.html) or browse the full [documentation](/docs/index.html).

The SDK is Apache 2.0 licensed, the same as the upstream Strands SDK. Contributions are welcome.
