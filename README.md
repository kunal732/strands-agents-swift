# Strands Agents Swift SDK

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20iOS%2017%2B%20%7C%20tvOS%2017%2B-lightgrey)](https://developer.apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.0%2B-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

Community Swift implementation of the [AWS Strands Agents](https://github.com/strands-agents/sdk-python) framework.

## What is Strands Agents?

[Strands Agents](https://github.com/strands-agents) is an open-source SDK created by AWS for building AI agents. An agent combines a model, tools, and a system prompt inside a loop. The loop receives user input, calls the model, executes any tools the model requests, and repeats until the model produces a final response.

AWS provides official implementations in [Python](https://github.com/strands-agents/sdk-python) and [TypeScript](https://github.com/strands-agents/sdk-typescript). This is an unofficial Swift implementation with additional support for on-device inference via MLX and native Apple audio I/O for voice agents.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/kunal732/strands-agents-swift.git", branch: "main")
]
```

Add the package to your target:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "StrandsAgents", package: "strands-agents-swift"),
])
```

That's it. All providers (Bedrock, MLX, Anthropic, OpenAI, Gemini), observability, and voice streaming are included in the single `StrandsAgents` module.

## Usage

```swift
import StrandsAgents

func wordCount(text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}
let wordCountTool = Tool(wordCount, "Count the number of words in text.")

let agent = Agent(
    model: try BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0"
    )),
    tools: [wordCountTool]
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

All providers ship in `StrandsAgents`. Import once, use any provider:

| Provider | Auth |
|----------|------|
| AWS Bedrock | Cognito / IAM credentials |
| Anthropic | `ANTHROPIC_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Google Gemini | `GOOGLE_API_KEY` |
| MLX (local) | None |

## Tools

Write a normal Swift function, wrap it with `Tool()` and a description. That's it.

```swift
func wordCount(text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}

func calculator(expression: String) -> String {
    let result = NSExpression(format: expression).expressionValue(with: nil, context: nil)
    return "\(result ?? "error")"
}

let wordCountTool = Tool(wordCount, "Count the number of words in text.")
let calculatorTool = Tool(calculator, "Evaluate a math expression.")

let agent = Agent(model: provider, tools: [wordCountTool, calculatorTool])
```

The tool name and parameter schema are inferred automatically. Your functions stay regular Swift functions that you can call directly:

```swift
let count = wordCount(text: "hello world")  // 2
```

You can also define tools inline:

```swift
let time = Tool("Get the current date and time.") {
    ISO8601DateFormatter().string(from: Date())
}
```

### @Tool macro (opt-in)

For zero-boilerplate tool definitions, add `StrandsAgentsToolMacros` to your target:

```swift
.product(name: "StrandsAgentsToolMacros", package: "strands-agents-swift")
```

Then annotate any function:

```swift
import StrandsAgentsToolMacros

/// Count the number of words in text.
@Tool
func wordCount(text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}

let agent = Agent(model: provider, tools: [wordCount])
```

The macro reads the function signature at compile time and generates the tool name, JSON schema, and description from the doc comment. Xcode will ask to trust the macro plugin on first use (one-time, per machine).

Tools requested in the same turn run concurrently by default.

## Structured Output

`runStructured` forces the model to produce JSON matching a schema you define, then decodes it directly into your Swift type. Under the hood it registers a hidden tool whose input schema is your type's `jsonSchema`; the model must call that tool to respond, guaranteeing the output is valid and decodable.

Apply `@StructuredOutput` to a `Codable` struct - the macro synthesizes the JSON schema automatically. Then call `agent.runStructured(prompt)`; the return type is inferred from context.

```swift
@StructuredOutput
struct Recipe {
    let name: String
    let ingredients: [String]
    let steps: [String]
    let note: String?   // optional - omitted from "required"
}

let agent = Agent(model: provider)
let recipe: Recipe = try await agent.runStructured("Give me a pasta recipe")

print(recipe.name)              // "Spaghetti Carbonara"
print(recipe.ingredients)       // ["200g spaghetti", "3 eggs", ...]
print(recipe.steps[0])          // "Boil salted water..."
```

The macro maps Swift types to JSON schema: `String` -> `"string"`, `Int` -> `"integer"`, `Double`/`Float` -> `"number"`, `Bool` -> `"boolean"`, `[T]` -> `"array"`, and `T?` marks the property optional (omitted from `"required"`).

If you need a custom schema, skip the macro and conform manually:

```swift
struct WeatherReport: StructuredOutput {
    let city: String
    let temperature: Double

    static var jsonSchema: JSONSchema {
        [
            "type": "object",
            "properties": [
                "city":        ["type": "string"],
                "temperature": ["type": "number"],
            ],
            "required": ["city", "temperature"],
        ]
    }
}
```

## Coming Soon

**Voice Agents (Bidirectional Streaming)** - Real-time voice conversation with tool calling. Cloud backends (OpenAI Realtime, AWS Nova Sonic, Google Gemini Live) and fully on-device voice (STT + LLM + TTS on Apple Silicon) are in active development. The infrastructure is built; we are working through platform-specific audio session issues before marking this stable.

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

| Module | Description |
|--------|-------------|
| `StrandsAgents` | Everything: agent, tools, all providers, observability, voice streaming |
| `StrandsAgentsToolMacros` | Opt-in `@Tool` and `@StructuredOutput` macros (triggers Xcode trust prompt) |

`StrandsAgents` includes Bedrock, MLX, Anthropic, OpenAI, and Gemini providers; OpenTelemetry observability; and bidirectional voice streaming -- all in one import. `StrandsAgentsToolMacros` is opt-in so users who only use `Tool()` never see the Xcode macro trust dialog.

## Platform Support

| Feature | macOS 14+ | iOS 17+ | tvOS 17+ |
|---------|-----------|---------|----------|
| Core agent + tools | Yes | Yes | Yes |
| Cloud providers | Yes | Yes | Yes |
| MLX local inference | Apple Silicon | - | - |
| Voice agents (cloud) | Yes | Yes | - |
| Voice agents (local) | Apple Silicon | - | - |

## Acknowledgments

- [Strands Agents](https://github.com/strands-agents) by AWS - the Python and TypeScript SDKs this implementation is based on
- [MLX Swift](https://github.com/ml-explore/mlx-swift) and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) by Apple - on-device ML framework
- [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift) by [Prince Canuma](https://github.com/Blaizzy) - speech-to-text, text-to-speech, and voice activity detection
- [AWS SDK for Swift](https://github.com/awslabs/aws-sdk-swift) - Bedrock Runtime client
- [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift) - distributed tracing
- [Swift Transformers](https://github.com/huggingface/swift-transformers) by Hugging Face - tokenizer support

## License

Apache 2.0
