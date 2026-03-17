# Strands Agents Swift SDK

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20iOS%2017%2B%20%7C%20tvOS%2017%2B-lightgrey)](https://developer.apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.0%2B-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Community Swift implementation of the [AWS Strands Agents](https://github.com/strands-agents/sdk-python) framework.

## What is Strands Agents?

[Strands Agents](https://github.com/strands-agents) is an open-source SDK created by AWS for building AI agents. An agent combines a model, tools, and a system prompt inside a loop. The loop receives user input, calls the model, executes any tools the model requests, and repeats until the model produces a final response.

AWS provides official implementations in [Python](https://github.com/strands-agents/sdk-python) and [TypeScript](https://github.com/strands-agents/sdk-typescript). This Swift implementation is at feature parity with those SDKs, with additional support for on-device inference via MLX and native Apple audio I/O for voice agents.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/kunal732/strands-agents-swift.git", branch: "main")
]
```

Add the modules you need:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "StrandsAgents", package: "strands-agents-swift"),
    .product(name: "StrandsBedrockProvider", package: "strands-agents-swift"),
])
```

## Usage

```swift
import StrandsAgents
import StrandsBedrockProvider

/// Count the number of words in text.
@Tool
func wordCount(text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}

let agent = Agent(
    model: try BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0"
    )),
    tools: [wordCount]
)

let result = try await agent.run("How many words are in this sentence?")
print(result)
```

### Streaming

`agent.stream()` returns tokens as they generate, so you can display the response in real time:

```swift
for try await event in agent.stream("How many words are in the Declaration of Independence?") {
    switch event {
    case .textDelta(let text):
        // Prints each token as it arrives (like a typing effect)
        print(text, terminator: "")
    case .toolResult(let result):
        print("\n[Tool returned: \(result.status)]")
    case .result(let final):
        print("\n\(final.metrics.totalLatencyMs)ms, \(final.usage.outputTokens) tokens")
    default: break
    }
}
```

### Local Inference

Run models on-device with Apple Silicon. Models download from HuggingFace and cache locally. No network or credentials required after download.

```swift
import StrandsMLXProvider

let agent = Agent(model: MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit"))
let result = try await agent.run("What is 42 * 17?")
```

### Hybrid Routing

Route between local and cloud models:

```swift
let agent = Agent(
    router: HybridRouter(
        local: MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit"),
        cloud: try BedrockProvider(config: BedrockConfig(
            modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0"
        )),
        policy: LatencySensitivePolicy()
    )
)
```

## Model Providers

| Provider | Module | Auth |
|----------|--------|------|
| AWS Bedrock | `StrandsBedrockProvider` | Cognito / IAM credentials |
| Anthropic | `StrandsAnthropicProvider` | `ANTHROPIC_API_KEY` |
| OpenAI | `StrandsOpenAIProvider` | `OPENAI_API_KEY` |
| Google Gemini | `StrandsGeminiProvider` | `GOOGLE_API_KEY` |
| MLX (local) | `StrandsMLXProvider` | None |

## Tools

The Swift implementation of Strands Agents uses a `@Tool` macro to generate the boilerplate for defining a tool. The macro derives the tool name, JSON schema, and `AgentTool` conformance from the function signature. The doc comment becomes the tool description that the model sees.

```swift
/// Count the number of words in text.
@Tool
func wordCount(text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}

/// Evaluate a math expression
@Tool
func calculator(expression: String) -> String {
    let result = NSExpression(format: expression).expressionValue(with: nil, context: nil)
    return "\(result ?? "error")"
}

let agent = Agent(model: provider, tools: [wordCount, calculator])
```

`@Tool` functions are still regular Swift functions -- you can call them directly:

```swift
let count = wordCount(text: "hello world")  // 2
```

### Defining tools without the macro

You can also define tools by conforming to the `AgentTool` protocol directly:

```swift
struct WordCount: AgentTool {
    let name = "word_count"

    var toolSpec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Count the number of words in text.",
            inputSchema: [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "The text to count words in"]],
                "required": ["text"],
            ]
        )
    }

    func call(toolUse: ToolUseBlock, context: ToolContext) async throws -> ToolResultBlock {
        let text = toolUse.input["text"]?.foundationValue as? String ?? ""
        let count = text.split(whereSeparator: \.isWhitespace).count
        return ToolResultBlock(
            toolUseId: toolUse.toolUseId,
            status: .success,
            content: [.text("\(count)")]
        )
    }
}

let agent = Agent(model: provider, tools: [WordCount()])
```

Tools requested in the same turn run concurrently by default.

## Structured Output

`runStructured` forces the model to produce JSON matching a schema you define, then decodes it directly into your Swift type. Under the hood it registers a hidden tool whose input schema is your type's `jsonSchema`; the model must call that tool to respond, guaranteeing the output is valid and decodable.

1. Define a `Codable` struct conforming to `StructuredOutput` and provide its JSON schema.
2. Call `agent.runStructured(prompt)` -- the return type is inferred from context.

```swift
struct Recipe: StructuredOutput {
    let name: String
    let ingredients: [String]
    let steps: [String]

    static var jsonSchema: JSONSchema {
        [
            "type": "object",
            "properties": [
                "name":        ["type": "string"],
                "ingredients": ["type": "array", "items": ["type": "string"]],
                "steps":       ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["name", "ingredients", "steps"],
        ]
    }
}

let agent = Agent(model: provider)
let recipe: Recipe = try await agent.runStructured("Give me a pasta recipe")

print(recipe.name)              // "Spaghetti Carbonara"
print(recipe.ingredients)       // ["200g spaghetti", "3 eggs", ...]
print(recipe.steps[0])          // "Boil salted water..."
```

## Multi-Agent

### Graph (DAG-based pipeline)

`GraphOrchestrator` runs agents as nodes in a directed acyclic graph. Each node declares which other nodes it depends on, so independent agents run in parallel while dependent agents wait for their inputs. Use this when the workflow is known up front and you want predictable, ordered execution.

```swift
let graph = GraphOrchestrator(nodes: [
    GraphNode(id: "research", agent: researchAgent),
    GraphNode(id: "write", agent: writerAgent, dependencies: ["research"]),
])
let result = try await graph.run("Write about quantum computing")
```

### Swarm (autonomous handoffs)

`SwarmOrchestrator` lets agents decide at runtime which agent should handle the next step. Execution starts at the entry-point agent; any agent can hand off to another by name based on the task at hand. Use this for open-ended workflows where the routing logic is too dynamic to express as a fixed graph.

```swift
let swarm = SwarmOrchestrator(members: [
    SwarmMember(id: "researcher", description: "Gathers information", agent: researchAgent),
    SwarmMember(id: "writer", description: "Writes articles", agent: writerAgent),
], entryPoint: "researcher")
let result = try await swarm.run("Write about quantum computing")
```

### A2A (Agent-to-Agent)

A2A lets agents communicate across process or network boundaries using a standard HTTP protocol. Serve any agent as an HTTP endpoint with `A2AServer`, then call it from another agent via `A2AClient` -- which acts as a regular tool from the calling agent's perspective. This enables distributing agents across services or machines without changing how they are defined.

```swift
// Serve an agent over HTTP
let server = A2AServer(agent: myAgent, name: "Research Agent", port: 8080)

// Call a remote agent as a tool
let remote = A2AClient(name: "research", description: "Remote researcher",
                       endpoint: URL(string: "https://research-agent.example.com")!)
let agent = Agent(model: provider, tools: [remote])
```

## Voice Agents (Bidirectional Streaming)

### Cloud

```swift
import StrandsBidiStreaming

let agent = BidiAgent(
    model: OpenAIRealtimeModel(model: "gpt-4o-realtime-preview"),
    tools: [wordCount],
    config: BidiSessionConfig(voice: "alloy")
)

try await agent.start()
Task { for await chunk in mic.audioStream { try await agent.send(.audio(chunk, format: .openAI)) } }
for try await event in agent.receive() {
    if case .audio(let data, _) = event { speaker.play(data) }
}
```

Supported backends: OpenAI Realtime, AWS Nova Sonic, Google Gemini Live.

### Local (fully on-device)

```swift
import StrandsMLXBidiProvider

let agent = MLXBidiFactory.createAgent(
    llmProcessor: MLXLLMProcessor(modelId: "mlx-community/Qwen3-8B-4bit"),
    sttProcessor: MLXSTTProcessor(model: glmASRModel),
    ttsProcessor: MLXTTSProcessor(model: sopranoModel),
    tools: [wordCount]
)
```

No network required. STT, LLM, and TTS all run on Apple Silicon.

## Authentication

### AWS Bedrock (production)

Use [AWS Amplify](https://docs.amplify.aws/swift/) with Cognito. Users authenticate through the app and receive temporary, scoped AWS credentials. No keys are embedded in the app binary.

```swift
import Amplify
import AWSCognitoAuthPlugin

try Amplify.add(plugin: AWSCognitoAuthPlugin())
try Amplify.configure()
try await Amplify.Auth.signIn(username: email, password: password)

// BedrockProvider picks up Cognito credentials automatically
let agent = Agent(model: try BedrockProvider(config: BedrockConfig(
    modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0"
)))
```

### API Keys (development)

```swift
let provider = AnthropicProvider(config: AnthropicConfig(apiKey: "sk-ant-..."))
// Or set ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY as environment variables
```

### Local

MLX inference requires no credentials or network.

## Observability

```swift
import StrandsOTelObservability

let agent = Agent(
    model: provider,
    observability: OTelObservabilityEngine(tracer: myTracer)
)
```

Exports to Datadog, Jaeger, AWS X-Ray, or any OTEL-compatible backend. Traces use the OpenTelemetry `gen_ai` semantic conventions for compatibility with Datadog LLM Observability.

Every invocation collects per-cycle metrics:

```swift
let result = try await agent.run("Hello")
print(result.metrics.cycleCount)
print(result.metrics.totalLatencyMs)
print(result.metrics.outputTokensPerSecond)

for cycle in result.metrics.cycles {
    print("Cycle \(cycle.cycleNumber): \(cycle.modelLatencyMs)ms, \(cycle.usage.outputTokens) tokens")
}
```

## Session Persistence

```swift
// File storage
let repo = FileSessionRepository(directory: sessionsDir)
let manager = RepositorySessionManager(sessionId: "user-123", repository: repo)
let agent = Agent(model: provider, sessionManager: manager)

// S3 storage (cross-device sync)
let repo = S3SessionRepository(bucket: "my-app-sessions", prefix: "users/\(userId)/")
```

Per-message persistence with atomic writes, version tracking, and broken history repair.

## Modules

| Module | Description | Dependencies |
|--------|-------------|-------------|
| `StrandsAgents` | Core: agent, tools, hooks, multi-agent, session, MCP | Foundation |
| `StrandsBedrockProvider` | AWS Bedrock ConverseStream | aws-sdk-swift |
| `StrandsMLXProvider` | On-device LLM inference | mlx-swift-lm |
| `StrandsAnthropicProvider` | Anthropic Messages API | -- |
| `StrandsOpenAIProvider` | OpenAI Chat Completions | -- |
| `StrandsGeminiProvider` | Google Gemini API | -- |
| `StrandsOTelObservability` | OpenTelemetry tracing | opentelemetry-swift |
| `StrandsBidiStreaming` | Voice agent protocols + cloud backends | aws-sdk-swift |
| `StrandsMLXBidiProvider` | Local STT/TTS/VAD pipeline | mlx-audio-swift |

## Platform Support

| Feature | macOS 14+ | iOS 17+ | tvOS 17+ |
|---------|-----------|---------|----------|
| Core agent + tools | Yes | Yes | Yes |
| Cloud providers | Yes | Yes | Yes |
| MLX local inference | Apple Silicon | -- | -- |
| Voice agents (cloud) | Yes | Yes | -- |
| Voice agents (local) | Apple Silicon | -- | -- |

## Acknowledgments

- [Strands Agents](https://github.com/strands-agents) by AWS -- the Python and TypeScript SDKs this implementation is based on
- [MLX Swift](https://github.com/ml-explore/mlx-swift) and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) by Apple -- on-device ML framework
- [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift) by [Prince Canuma](https://github.com/Blaizzy) -- speech-to-text, text-to-speech, and voice activity detection
- [AWS SDK for Swift](https://github.com/awslabs/aws-sdk-swift) -- Bedrock Runtime client
- [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift) -- distributed tracing
- [Swift Transformers](https://github.com/huggingface/swift-transformers) by Hugging Face -- tokenizer support

## License

MIT
