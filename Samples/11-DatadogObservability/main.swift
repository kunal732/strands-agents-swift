// 11 - Datadog LLM Observability
// Sends OTel traces with GenAI semantic conventions to Datadog.
// Every agent run, model call, and tool execution appears as a connected trace.
//
// Set DD_API_KEY before running. Traces appear in Datadog LLM Observability.

import Foundation
import StrandsAgents
import StrandsAgentsToolMacros

@Tool
func calculator(expression: String) -> String {
    guard let result = NSExpression(format: expression).expressionValue(with: nil, context: nil) else {
        return "Error: invalid expression"
    }
    return "\(result)"
}

@Tool
func getCurrentTime(timezone: String = "local") -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
    return formatter.string(from: Date())
}

let ddApiKey = ProcessInfo.processInfo.environment["DD_API_KEY"] ?? ""
guard !ddApiKey.isEmpty else {
    print("Set DD_API_KEY environment variable to send traces to Datadog.")
    exit(1)
}

let agent = Agent(
    model: try BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
        region: "us-east-1"
    )),
    tools: [calculator, getCurrentTime],
    systemPrompt: "You are a helpful assistant. Use tools when needed. Be concise.",
    observability: OTelObservabilityEngine.datadog(
        apiKey: ddApiKey,
        service: "strands-sample",
        version: "0.0.1"
    )
)

print("Datadog OTel tracing enabled. Traces will appear in LLM Observability.\n")

// Run 1: tool calling (produces invoke_agent > cycle > chat + tool spans)
let prompt1 = "What is 123 * 456? Also, what time is it?"
print("Prompt: \(prompt1)")
let result1 = try await agent.run(prompt1)
print("Agent: \(result1.message.textContent ?? "")")
print("Cycles: \(result1.metrics.cycleCount), Tokens: \(result1.usage.totalTokens)\n")

// Run 2: simple question (produces invoke_agent > cycle > chat)
let prompt2 = "What is the capital of Japan?"
print("Prompt: \(prompt2)")
let result2 = try await agent.run(prompt2)
print("Agent: \(result2.message.textContent ?? "")")
print("Cycles: \(result2.metrics.cycleCount), Tokens: \(result2.usage.totalTokens)\n")

print("Check Datadog LLM Observability for traces.")
print("Span hierarchy: invoke_agent > execute_event_loop_cycle > chat + execute_tool")
