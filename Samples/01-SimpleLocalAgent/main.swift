// 01 - Simple Local Agent
// Runs a Qwen3 model on-device with a word count tool.
// No network or API keys required after first model download.

import Foundation
import StrandsAgents

func wordCount(text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}
let wordCountTool = Tool(wordCount, "Count the number of words in the given text.", name: "word_count")

let agent = Agent(
    model: MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit"),
    tools: [wordCountTool],
    systemPrompt: "You are a helpful assistant. Use tools when needed. Be concise."
)

print("Loading model (downloads on first run)...")

let prompt = "How many words are in: 'The quick brown fox jumps over the lazy dog'"
print("Prompt: \(prompt)\n")

for try await event in agent.stream(prompt) {
    switch event {
    case .textDelta(let token):
        print(token, terminator: "")
    case .toolResult(let result):
        let text = result.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        print("[Tool: \(text)]")
    case .result(let result):
        print("\n\nTokens: \(result.usage.inputTokens) in / \(result.usage.outputTokens) out")
    default:
        break
    }
}
