// 03 - Hybrid Agent
// Routes between local MLX and cloud Bedrock based on routing hints.
// Privacy-sensitive prompts stay on-device; complex tasks go to the cloud.

import Foundation
import StrandsAgents
import StrandsMLXProvider
import StrandsBedrockProvider

@Tool
func getCurrentTime() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date())
}

let agent = Agent(
    router: HybridRouter(
        local: MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit"),
        cloud: try BedrockProvider(config: BedrockConfig(
            modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
            region: "us-east-1"
        )),
        policy: LatencySensitivePolicy()
    ),
    tools: [getCurrentTime],
    systemPrompt: "You are a helpful assistant. Be concise."
)

// 1. Privacy-sensitive prompt: routes to local MLX
print("--- Privacy-sensitive (routes local) ---")
agent.routingHints = RoutingHints(privacySensitive: true)
let local = try await agent.run("What time is it? Also, my SSN is 123-45-6789. Don't repeat it.")
print(local.message.textContent ?? "")

// 2. Deep reasoning prompt: routes to cloud Bedrock
print("\n--- Deep reasoning (routes cloud) ---")
agent.routingHints = RoutingHints(requiresDeepReasoning: true)
let cloud = try await agent.run("Explain the difference between actors and classes in Swift concurrency.")
print(cloud.message.textContent ?? "")

// 3. Force local regardless of policy
print("\n--- Forced local ---")
agent.routingHints = RoutingHints(forceProvider: .local)
let forced = try await agent.run("What is 2 + 2?")
print(forced.message.textContent ?? "")
