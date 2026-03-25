import Foundation
import StrandsAgents

// MARK: - Configuration

let modelId = "mlx-community/Qwen3-8B-4bit"

// MARK: - Tool Definitions

let weatherTool = FunctionTool(
    name: "get_weather",
    description: "Get the current weather for a given city",
    inputSchema: [
        "type": "object",
        "properties": [
            "city": [
                "type": "string",
                "description": "The city name, e.g. 'San Francisco'",
            ],
        ],
        "required": ["city"],
    ]
) { (input: JSONValue, _: ToolContext) async throws -> String in
    let city = input["city"]?.foundationValue as? String ?? "unknown"
    // Simulated weather data
    let conditions = ["sunny", "cloudy", "rainy", "partly cloudy", "windy"]
    let temp = Int.random(in: 55...85)
    let condition = conditions.randomElement()!
    return "Weather in \(city): \(temp) F, \(condition)"
}

let calculatorTool = FunctionTool(
    name: "calculator",
    description: "Evaluate a mathematical expression and return the result",
    inputSchema: [
        "type": "object",
        "properties": [
            "expression": [
                "type": "string",
                "description": "The math expression to evaluate, e.g. '2 + 2' or '15 * 7'",
            ],
        ],
        "required": ["expression"],
    ]
) { (input: JSONValue, _: ToolContext) async throws -> String in
    let expr = input["expression"]?.foundationValue as? String ?? "0"
    // Simple eval using NSExpression
    let nsExpr = NSExpression(format: expr)
    if let result = nsExpr.expressionValue(with: nil, context: nil) {
        return "Result: \(result)"
    }
    return "Could not evaluate: \(expr)"
}

// MARK: - Run Tests

@Sendable
func runBasicInference() async throws {
    print("=" * 60)
    print("TEST 1: Basic Local Inference")
    print("Model: \(modelId)")
    print("=" * 60)

    let provider = MLXProvider(config: MLXConfig(
        modelId: modelId,
        maxTokens: 200,
        temperature: 0.7
    ))

    print("\nLoading model (this may download on first run)...")
    try await provider.preload()
    print("Model loaded.\n")

    let agent = Agent(model: provider, systemPrompt: "You are a helpful assistant. Keep responses concise.")

    print("Prompt: What are 3 interesting facts about Swift programming?")
    print("\nResponse:")
    print("-" * 40)

    for try await event in agent.stream("What are 3 interesting facts about Swift programming?") {
        switch event {
        case .textDelta(let text):
            print(text, terminator: "")
        case .result(let result):
            print("\n" + "-" * 40)
            print("Stop reason: \(result.stopReason)")
            print("Tokens: \(result.usage.inputTokens) in / \(result.usage.outputTokens) out")
            print("Cycles: \(result.cycleCount)")
        default:
            break
        }
    }
    print()
}

@Sendable
func runToolCalling() async throws {
    print("\n" + "=" * 60)
    print("TEST 2: Tool Calling")
    print("Model: \(modelId)")
    print("=" * 60)

    let provider = MLXProvider(config: MLXConfig(
        modelId: modelId,
        maxTokens: 500,
        temperature: 0.3
    ))

    let agent = Agent(
        model: provider,
        tools: [weatherTool, calculatorTool],
        systemPrompt: "You are a helpful assistant with access to tools. Use tools when needed to answer questions accurately."
    )

    let prompt = "What's the weather in San Francisco and what is 42 * 17?"
    print("\nPrompt: \(prompt)")
    print("\nAgent running...")
    print("-" * 40)

    for try await event in agent.stream(prompt) {
        switch event {
        case .textDelta(let text):
            print(text, terminator: "")
        case .toolResult(let result):
            let content = result.content.map { c -> String in
                if case .text(let t) = c { return t }
                return ""
            }.joined()
            print("\n[Tool Result: \(content)]")
        case .result(let result):
            print("\n" + "-" * 40)
            print("Stop reason: \(result.stopReason)")
            print("Tokens: \(result.usage.inputTokens) in / \(result.usage.outputTokens) out")
            print("Cycles: \(result.cycleCount)")
        default:
            break
        }
    }
    print()
}

@Sendable
func runMultiTurn() async throws {
    print("\n" + "=" * 60)
    print("TEST 3: Multi-Turn Conversation")
    print("Model: \(modelId)")
    print("=" * 60)

    let provider = MLXProvider(config: MLXConfig(
        modelId: modelId,
        maxTokens: 150,
        temperature: 0.7
    ))

    let agent = Agent(model: provider, systemPrompt: "You are a helpful assistant. Keep responses concise.")

    let prompts = [
        "What is the capital of France?",
        "What's a famous landmark there?",
        "How tall is it in meters?",
    ]

    for prompt in prompts {
        print("\nUser: \(prompt)")
        print("Assistant: ", terminator: "")

        let result = try await agent.run(prompt)
        print(result.message.textContent)
    }

    print("\nConversation history: \(agent.messages.count) messages")
    print()
}

// MARK: - Helpers

extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}

// MARK: - Main

do {
    try await runBasicInference()
    try await runToolCalling()
    try await runMultiTurn()

    print("\n" + "=" * 60)
    print("All tests completed!")
    print("=" * 60)
} catch {
    print("\nError: \(error)")
    if let strandsError = error as? StrandsError {
        print("Strands error: \(strandsError.localizedDescription)")
    }
}
