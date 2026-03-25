// 02 - Simple Bedrock Agent
// Calls Claude via AWS Bedrock with a calculator tool.
// Requires AWS credentials (environment, ~/.aws/credentials, or Cognito).

import Foundation
import StrandsAgents

func calculator(expression: String) -> String {
    guard let result = NSExpression(format: expression).expressionValue(with: nil, context: nil) else {
        return "Error: invalid expression"
    }
    return "\(result)"
}
let calculatorTool = Tool(calculator, "Evaluate a math expression.", name: "calculator")

let agent = Agent(
    model: try BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
        region: "us-east-1"
    )),
    tools: [calculatorTool],
    systemPrompt: "You are a helpful assistant. Use the calculator tool for math. Be concise."
)

let prompt = "What is 1234 * 5678 + 42?"
print("Prompt: \(prompt)\n")

for try await event in agent.stream(prompt) {
    switch event {
    case .textDelta(let token):
        print(token, terminator: "")
    case .toolResult(let result):
        let text = result.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        print("[Calculator: \(text)]")
    case .result(let result):
        print("\n\nTokens: \(result.usage.inputTokens) in / \(result.usage.outputTokens) out")
    default:
        break
    }
}
