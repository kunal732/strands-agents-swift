import Foundation
import StrandsAgents

// MARK: - Configuration

let modelId = "us.anthropic.claude-sonnet-4-20250514-v1:0"
let region = "us-east-1"

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
    let conditions = ["sunny", "cloudy", "rainy", "partly cloudy", "windy"]
    let temp = Int.random(in: 55...85)
    let condition = conditions.randomElement()!
    return "Weather in \(city): \(temp)°F, \(condition)"
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
    let nsExpr = NSExpression(format: expr)
    if let result = nsExpr.expressionValue(with: nil, context: nil) {
        return "Result: \(result)"
    }
    return "Could not evaluate: \(expr)"
}

// MARK: - Helpers

extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}

// MARK: - Tests

@Sendable
func runBasicInference() async throws {
    print("=" * 60)
    print("TEST 1: Bedrock Basic Inference")
    print("Model: \(modelId)")
    print("Region: \(region)")
    print("=" * 60)

    let provider = try BedrockProvider(config: BedrockConfig(
        modelId: modelId,
        region: region,
        maxTokens: 256
    ))

    let agent = Agent(
        model: provider,
        systemPrompt: "You are a helpful assistant. Keep responses concise -- 2-3 sentences max."
    )

    let prompt = "What are 3 interesting facts about Swift programming?"
    print("\nPrompt: \(prompt)")
    print("\nResponse:")
    print("-" * 40)

    for try await event in agent.stream(prompt) {
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
    print("TEST 2: Bedrock Tool Calling")
    print("Model: \(modelId)")
    print("=" * 60)

    let provider = try BedrockProvider(config: BedrockConfig(
        modelId: modelId,
        region: region,
        maxTokens: 512
    ))

    let agent = Agent(
        model: provider,
        tools: [weatherTool, calculatorTool],
        systemPrompt: "You are a helpful assistant. Use tools when needed. Be concise."
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
            print("\n  [Tool '\(result.toolUseId.prefix(8))...' -> \(result.status): \(content)]")
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
    print("TEST 3: Bedrock Multi-Turn Conversation")
    print("Model: \(modelId)")
    print("=" * 60)

    let provider = try BedrockProvider(config: BedrockConfig(
        modelId: modelId,
        region: region,
        maxTokens: 128
    ))

    let agent = Agent(
        model: provider,
        systemPrompt: "You are a helpful assistant. Answer in 1-2 sentences."
    )

    let prompts = [
        "What is the capital of Japan?",
        "What's a famous temple there?",
        "When was it built?",
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

// MARK: - Main

do {
    try await runBasicInference()
    try await runToolCalling()
    try await runMultiTurn()

    print("\n" + "=" * 60)
    print("All Bedrock tests completed!")
    print("=" * 60)
} catch {
    print("\nError: \(error)")
    if let strandsError = error as? StrandsError {
        print("Strands error: \(strandsError.localizedDescription)")
    }
}
