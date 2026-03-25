// 08 - Multiple Non-Bedrock Providers
// Runs the same prompt through Anthropic, OpenAI, and Gemini in one app.
// Demonstrates that tools and agent code are identical across providers.
//
// Set these environment variables before running:
//   ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY

import Foundation
import StrandsAgents
import StrandsAnthropicProvider
import StrandsOpenAIProvider
import StrandsGeminiProvider
import StrandsAgentsToolMacros

@Tool
func calculator(expression: String) -> String {
    guard let result = NSExpression(format: expression).expressionValue(with: nil, context: nil) else {
        return "Error: invalid expression"
    }
    return "\(result)"
}

let prompt = "What is 99 * 77? Use the calculator tool."

let providers: [(String, any ModelProvider)] = [
    ("Anthropic", AnthropicProvider(config: AnthropicConfig(
        modelId: "claude-sonnet-4-5-20251001",
        apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    ))),
    ("OpenAI", OpenAIProvider(config: OpenAIConfig(
        modelId: "gpt-4o",
        apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    ))),
    ("Gemini", GeminiProvider(config: GeminiConfig(
        modelId: "gemini-2.0-flash",
        apiKey: ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
    ))),
]

for (name, provider) in providers {
    print("=== \(name) ===")

    let agent = Agent(
        model: provider,
        tools: [calculator],
        systemPrompt: "You are a helpful assistant. Use the calculator tool for math. Be concise."
    )

    do {
        let result = try await agent.run(prompt)
        print(result.message.textContent ?? "(no text)")
        print("Tokens: \(result.usage.inputTokens) in / \(result.usage.outputTokens) out")
    } catch {
        print("Error: \(error.localizedDescription)")
    }

    print()
}
