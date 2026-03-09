# Strands Agents Swift SDK

A community-driven Swift implementation of the [AWS Strands Agents](https://github.com/strands-agents/sdk-python) framework for macOS, iOS, and tvOS.

## What is Strands Agents?

[Strands Agents](https://github.com/strands-agents) is an open-source SDK created by AWS for building AI agents. An agent combines a model, tools, and a system prompt inside a loop. The loop receives user input, calls the model, executes any tools the model requests, and repeats until the model produces a final response. The SDK handles streaming, conversation history, retries, and observability.

AWS provides official implementations in [Python](https://github.com/strands-agents/sdk-python) and [TypeScript](https://github.com/strands-agents/sdk-typescript). This is a community Swift implementation at feature parity with those SDKs, with additional support for on-device inference via MLX and native Apple audio I/O for voice agents.

**Reference implementations:**
- [Python SDK](https://github.com/strands-agents/sdk-python)
- [TypeScript SDK](https://github.com/strands-agents/sdk-typescript)

## Quick Start

### Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/anthropics/strands-agents-swift.git", branch: "main")
]
```

Then add the targets you need:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "StrandsAgents", package: "strands-agents-swift"),
        .product(name: "StrandsBedrockProvider", package: "strands-agents-swift"),
    ]
)
```

### Basic Usage

```swift
import StrandsAgents
import StrandsBedrockProvider

let agent = Agent(
    model: try BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0"
    )),
    tools: [WeatherTool()],
    systemPrompt: "You are a helpful assistant."
)

let result = try await agent.run("What's the weather in San Francisco?")
print(result)
```

### Streaming

```swift
for try await event in agent.stream("Tell me a story") {
    switch event {
    case .textDelta(let text):
        print(text, terminator: "")
    case .toolResult(let result):
        print("\n[Tool: \(result.status)]")
    case .result(let result):
        print("\nTokens: \(result.usage.inputTokens)in / \(result.usage.outputTokens)out")
    default: break
    }
}
```

## Model Providers

### Cloud Providers

| Provider | Target | Models | Auth |
|----------|--------|--------|------|
| **AWS Bedrock** | `StrandsBedrockProvider` | Claude, Llama, Mistral, Nova, Cohere | AWS credentials (Cognito / IAM) |
| **Anthropic** | `StrandsAnthropicProvider` | Claude family | API key (`ANTHROPIC_API_KEY`) |
| **OpenAI** | `StrandsOpenAIProvider` | GPT-4o, o3, compatible APIs | API key (`OPENAI_API_KEY`) |
| **Google Gemini** | `StrandsGeminiProvider` | Gemini 2.5 Flash/Pro | API key (`GOOGLE_API_KEY`) |

### Local Providers

| Provider | Target | Models | Requirements |
|----------|--------|--------|-------------|
| **MLX** | `StrandsMLXProvider` | Any HuggingFace MLX model | macOS, Apple Silicon |

```swift
// Cloud: AWS Bedrock
let agent = Agent(model: try BedrockProvider(config: BedrockConfig(
    modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0"
)))

// Cloud: Anthropic direct
let agent = Agent(model: AnthropicProvider(config: AnthropicConfig(
    modelId: "claude-sonnet-4-20250514"
)))

// Cloud: Gemini
let agent = Agent(model: GeminiProvider(config: GeminiConfig(
    modelId: "gemini-2.5-flash"
)))

// Local: MLX (downloads from HuggingFace, runs on Apple Silicon)
let agent = Agent(model: MLXProvider(config: MLXConfig(
    modelId: "mlx-community/Qwen3-8B-4bit"
)))
```

### Hybrid Routing

Route between local and cloud models based on context:

```swift
let agent = Agent(
    router: HybridRouter(
        local: MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit"),
        cloud: try BedrockProvider(config: BedrockConfig(
            modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0"
        )),
        policy: LatencySensitivePolicy()
    ),
    tools: [MyTool()]
)
```

Built-in routing policies: `AlwaysLocalPolicy`, `AlwaysCloudPolicy`, `LatencySensitivePolicy`, `FallbackPolicy`. Implement `RoutingPolicy` for custom logic.

## Tools

### Defining Tools

```swift
// Closure-based
let calculator = FunctionTool(
    name: "calculator",
    description: "Evaluate a math expression",
    inputSchema: ToolSchemaBuilder.build {
        StringProperty("expression", description: "The math expression").required()
    }
) { input, context in
    let expr = input["expression"]?.foundationValue as? String ?? "0"
    let result = NSExpression(format: expr).expressionValue(with: nil, context: nil)
    return "Result: \(result ?? "error")"
}

// Protocol-based
struct WeatherTool: AgentTool {
    let name = "get_weather"
    var toolSpec: ToolSpec {
        ToolSpec(name: name, description: "Get weather for a city", inputSchema: [
            "type": "object",
            "properties": ["city": ["type": "string"]],
            "required": ["city"],
        ])
    }

    func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        let city = toolUse.input["city"]?.foundationValue as? String ?? ""
        return ToolResultBlock(toolUseId: toolUse.toolUseId, status: .success,
                               content: [.text("72F, sunny in \(city)")])
    }
}
```

### Direct Tool Calling

```swift
let result = try await agent.callTool("calculator", input: ["expression": "42 * 17"])
```

### Tool Providers & MCP

```swift
// Load tools from an MCP server
let mcp = MCPToolProvider(command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
try await agent.toolRegistry.loadFrom(mcp)

// Load tools from JSON schema files
let provider = JSONSchemaToolProvider(directory: toolsDir) { name, input, ctx in
    // dispatch to implementation
}
```

### Concurrent Tool Execution

When the model requests multiple tools in one turn, they run in parallel via `TaskGroup`:

```swift
let agent = Agent(model: provider, tools: [tool1, tool2, tool3],
                  parallelToolExecution: true)  // default
```

## Structured Output

```swift
struct Recipe: StructuredOutput {
    let name: String
    let ingredients: [String]
    let steps: [String]

    static var jsonSchema: JSONSchema {
        ToolSchemaBuilder.build {
            StringProperty("name", description: "Recipe name").required()
            ArrayProperty("ingredients", description: "Ingredient list").required()
            ArrayProperty("steps", description: "Cooking steps").required()
        }
    }
}

let recipe: Recipe = try await agent.runStructured("Give me a pasta recipe")
print(recipe.name)       // "Spaghetti Carbonara"
print(recipe.ingredients) // ["spaghetti", "eggs", "pancetta", ...]
```

## Multi-Agent Orchestration

### Graph (DAG-based)

```swift
let graph = GraphOrchestrator(nodes: [
    GraphNode(id: "research", agent: researchAgent),
    GraphNode(id: "write", agent: writerAgent, dependencies: ["research"]),
    GraphNode(id: "edit", agent: editorAgent, dependencies: ["write"]),
])

let result = try await graph.run("Write about quantum computing")
// research runs first, then write, then edit
```

### Swarm (autonomous handoffs)

```swift
let swarm = SwarmOrchestrator(
    members: [
        SwarmMember(id: "researcher", description: "Gathers information", agent: researchAgent),
        SwarmMember(id: "writer", description: "Writes articles", agent: writerAgent),
    ],
    entryPoint: "researcher"
)

let result = try await swarm.run("Write about quantum computing")
// researcher decides when to hand off to writer via injected tool
```

### A2A (Agent-to-Agent)

```swift
// Expose an agent as an A2A service
let server = A2AServer(agent: myAgent, name: "Research Agent", port: 8080)

// Call a remote A2A agent as a tool
let remoteAgent = A2AClient(name: "research", description: "Remote researcher",
                            endpoint: URL(string: "https://research-agent.example.com")!)
let agent = Agent(model: provider, tools: [remoteAgent])
```

## Bidirectional Streaming (Voice Agents)

Real-time voice conversations with simultaneous audio input and output.

### Cloud Voice (OpenAI Realtime / Nova Sonic / Gemini Live)

```swift
import StrandsBidiStreaming

let agent = BidiAgent(
    model: OpenAIRealtimeModel(model: "gpt-4o-realtime-preview"),
    tools: [WeatherTool()],
    config: BidiSessionConfig(voice: "alloy")
)

try await agent.start()

// Send microphone audio
let mic = MicrophoneInput(format: .openAI)
try mic.start()
Task { for await chunk in mic.audioStream { try await agent.send(.audio(chunk, format: .openAI)) } }

// Play responses
let speaker = SpeakerOutput(format: .openAI)
try speaker.start()
for try await event in agent.receive() {
    switch event {
    case .audio(let data, _): speaker.play(data)
    case .textDelta(let text): print(text, terminator: "")
    case .toolCall(let tu): print("[Calling \(tu.name)]")
    default: break
    }
}
```

### Local Voice (Fully On-Device)

All processing on Apple Silicon -- no network required:

```swift
import StrandsMLXBidiProvider

let agent = MLXBidiFactory.createAgent(
    llmProcessor: MLXLLMProcessor(modelId: "mlx-community/Qwen3-8B-4bit"),
    sttProcessor: MLXSTTProcessor(model: glmASRModel),
    ttsProcessor: MLXTTSProcessor(model: sopranoModel),
    tools: [WeatherTool()],
    systemPrompt: "You are a helpful voice assistant."
)
```

**Supported bidi backends:**

| Backend | Connection | Use Case |
|---------|-----------|----------|
| OpenAI Realtime | WebSocket | GPT-4o voice |
| Nova Sonic | Bedrock bidi stream | AWS-native voice |
| Gemini Live | WebSocket | Google multimodal |
| Local MLX | On-device pipeline | Offline, private |

## On-Device Inference

The SDK supports fully local inference on Apple Silicon using [MLX](https://github.com/ml-explore/mlx-swift). Models are downloaded from HuggingFace and cached locally.

```swift
import StrandsMLXProvider

// Any HuggingFace MLX model works -- just pass the model ID
let provider = MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit")

// Preload for faster first response
try await provider.preload()

let agent = Agent(model: provider, tools: [calculator])
let result = try await agent.run("What is 42 * 17?")
```

**What runs locally:**
- LLM inference (text generation, tool calling)
- Speech-to-text (via mlx-audio-swift)
- Text-to-speech (via mlx-audio-swift)
- Voice activity detection (via mlx-audio-swift)

**Requirements:** macOS 14+ with Apple Silicon (M1 or later). 16GB+ RAM recommended for 8B models.

## Authentication

### AWS Bedrock (recommended for production)

Use [AWS Amplify](https://docs.amplify.aws/swift/) with Cognito for mobile auth:

```swift
import Amplify
import AWSCognitoAuthPlugin

// 1. Configure Amplify (reads amplifyconfiguration.json)
try Amplify.add(plugin: AWSCognitoAuthPlugin())
try Amplify.configure()

// 2. User signs in (Apple, Google, email, etc.)
try await Amplify.Auth.signIn(username: email, password: password)

// 3. BedrockProvider automatically uses Cognito credentials
let agent = Agent(model: try BedrockProvider(config: BedrockConfig(
    modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0"
)))
```

The developer sets up a Cognito User Pool + Identity Pool in AWS, with an IAM role scoped to Bedrock access. Users authenticate through the app, receive temporary credentials, and call Bedrock directly. No AWS keys are embedded in the app.

### Direct API Keys

For development or non-AWS providers, set API keys via environment variables or pass them directly:

```swift
// Environment variable (recommended)
export ANTHROPIC_API_KEY=sk-ant-...

// Or pass directly
let provider = AnthropicProvider(config: AnthropicConfig(apiKey: "sk-ant-..."))
```

### Local (no auth needed)

MLX inference requires no credentials or network connection.

## Observability

### OpenTelemetry

```swift
import StrandsOTelObservability

let tracer = OpenTelemetry.instance.tracerProvider
    .get(instrumentationName: "my-app", instrumentationVersion: "1.0")

let agent = Agent(
    model: provider,
    observability: OTelObservabilityEngine(tracer: tracer)
)
```

Export to Datadog, Jaeger, AWS X-Ray, or any OTEL-compatible backend.

### Per-Cycle Metrics

Every agent invocation collects detailed metrics:

```swift
let result = try await agent.run("Hello")

print(result.metrics.cycleCount)              // 2
print(result.metrics.totalLatencyMs)          // 1234
print(result.metrics.outputTokensPerSecond)   // 45.2
print(result.metrics.averageTimeToFirstTokenMs) // 180

for cycle in result.metrics.cycles {
    print("Cycle \(cycle.cycleNumber): \(cycle.modelLatencyMs)ms, " +
          "\(cycle.usage.outputTokens) tokens, " +
          "tools: \(cycle.toolLatencies)")
}
```

Metrics emitted to the observability engine:
- `strands.cycle.model_latency_ms` -- per-cycle model call time
- `strands.cycle.ttft_ms` -- time to first token
- `strands.cycle.input_tokens` / `strands.cycle.output_tokens`
- `strands.invocation.total_latency_ms` -- full invocation time
- `strands.invocation.output_tokens_per_second`
- `strands.invocation.cycle_count`

## Session Persistence

### File Storage

```swift
let repo = FileSessionRepository(directory: URL(fileURLWithPath: "~/.myapp/sessions"))
let manager = RepositorySessionManager(sessionId: "user-123", repository: repo)
let agent = Agent(model: provider, sessionManager: manager)

// First run: new session
let restored = try await manager.initializeAgent(agent: agent)

// Later: restore previous conversation
let messages = try await manager.initializeAgent(agent: agent)
// messages contains the full conversation history
```

### S3 Storage (cross-device sync)

```swift
let repo = S3SessionRepository(bucket: "my-app-sessions", prefix: "users/\(userId)/")
let manager = RepositorySessionManager(sessionId: sessionId, repository: repo)
```

Sessions are persisted per-message with atomic writes, version tracking, and broken history repair.

## Plugins

```swift
struct LoggingPlugin: AgentPlugin {
    func configure(agent: Agent) {
        agent.hookRegistry.addCallback(BeforeModelCallEvent.self) { event in
            print("Calling model with \(event.messages.count) messages")
        }
        agent.hookRegistry.addCallback(AfterToolCallEvent.self) { event in
            print("Tool \(event.toolUse.name) returned \(event.result.status)")
        }
    }
}

let agent = Agent(model: provider, plugins: [LoggingPlugin()])
```

## Steering

Context-driven guidance injected at runtime:

```swift
struct SafetySteeringHandler: SteeringHandler {
    func evaluate(context: SteeringContext) async -> SteeringAction {
        if context.lastToolCall == "delete_files" {
            return .guide("Confirm with the user before deleting.")
        }
        return .proceed
    }
}
```

## Architecture

```
┌──────────────────────────────────────────────────┐
│                  StrandsAgents                    │
│  Agent, AgentLoop, Tools, Hooks, Multi-Agent,    │
│  Session, Observability, Steering, Plugins       │
│  (Foundation only -- zero external dependencies) │
└───────────────┬──────────────────────────────────┘
                │
    ┌───────────┼───────────┬──────────────┐
    │           │           │              │
┌───▼───┐  ┌───▼───┐  ┌────▼────┐  ┌──────▼──────┐
│Bedrock│  │  MLX  │  │Anthropic│  │   Gemini    │
│  AWS  │  │ Local │  │  Direct │  │   Google    │
└───────┘  └───────┘  └─────────┘  └─────────────┘
                │
        ┌───────┼───────┐
        │       │       │
    ┌───▼──┐ ┌──▼──┐ ┌──▼──┐
    │ STT  │ │ TTS │ │ VAD │
    │ MLX  │ │ MLX │ │ MLX │
    │Audio │ │Audio│ │Audio│
    └──────┘ └─────┘ └─────┘
```

## Module Reference

| Module | What it provides | Dependencies |
|--------|-----------------|-------------|
| `StrandsAgents` | Core agent, tools, hooks, multi-agent, session, MCP | Foundation only |
| `StrandsBedrockProvider` | AWS Bedrock ConverseStream + bidi | aws-sdk-swift |
| `StrandsMLXProvider` | On-device LLM/VLM inference | mlx-swift-lm |
| `StrandsAnthropicProvider` | Anthropic Messages API | None (URLSession) |
| `StrandsOpenAIProvider` | OpenAI Chat Completions | None (URLSession) |
| `StrandsGeminiProvider` | Google Gemini API | None (URLSession) |
| `StrandsOTelObservability` | OpenTelemetry tracing | opentelemetry-swift |
| `StrandsBidiStreaming` | Voice agent protocols + cloud models | aws-sdk-swift |
| `StrandsMLXBidiProvider` | Local STT/TTS/VAD pipeline | mlx-audio-swift |

## Platform Support

| Feature | macOS 14+ | iOS 17+ | tvOS 17+ |
|---------|-----------|---------|----------|
| Core agent + tools | Yes | Yes | Yes |
| Cloud providers | Yes | Yes | Yes |
| MLX local inference | Yes (Apple Silicon) | No | No |
| Bidi voice (cloud) | Yes | Yes | No |
| Bidi voice (local) | Yes (Apple Silicon) | No | No |
| Audio I/O | Yes | Yes | No |

## Acknowledgments

This SDK builds on the work of several open-source projects:

- **[Strands Agents SDK (Python)](https://github.com/strands-agents/sdk-python)** and **[TypeScript](https://github.com/strands-agents/sdk-typescript)** by AWS -- the reference implementations this SDK is based on
- **[MLX Swift](https://github.com/ml-explore/mlx-swift)** and **[MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)** by Apple -- on-device machine learning framework for Apple Silicon
- **[MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift)** by Prince Canuma ([@Blaizzy](https://github.com/Blaizzy)) -- speech-to-text, text-to-speech, and voice activity detection for MLX
- **[AWS SDK for Swift](https://github.com/awslabs/aws-sdk-swift)** by AWS -- Bedrock Runtime client
- **[OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift)** -- distributed tracing and observability
- **[Swift Transformers](https://github.com/huggingface/swift-transformers)** by Hugging Face -- tokenizer support

## License

MIT
