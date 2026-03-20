// 05 - MLX Bidirectional Streaming (Fully Local)
// Voice agent running entirely on Apple Silicon.
// STT, LLM, and TTS all on-device. No network required after model download.

import Foundation
import StrandsAgents
import StrandsMLXBidiProvider

@Tool
func getCurrentTime() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: Date())
}

print("Loading local voice models (STT + LLM + TTS)...")

let agent = try await MLXBidiFactory.createAgent(
    llmProcessor: MLXLLMProcessor(modelId: "mlx-community/Qwen3-8B-4bit"),
    sttProcessor: MLXSTTProcessor.load(model: .glmASR),
    ttsProcessor: MLXTTSProcessor.load(model: .soprano),
    tools: [getCurrentTime],
    systemPrompt: "You are a helpful on-device voice assistant. Keep responses short."
)

print("Local voice agent ready.")

try await agent.start()

// In a real app, connect AVAudioEngine for mic input and speaker output:
//
// Task {
//     for await chunk in audioEngine.inputStream {
//         try await agent.send(.audio(chunk, format: .pcm16))
//     }
// }
//
// for try await event in agent.receive() {
//     switch event {
//     case .audio(let data, _):
//         audioEngine.play(data)
//     case .transcript(let text):
//         print("Agent: \(text)")
//     default:
//         break
//     }
// }

print("Connect audio I/O to start a conversation.")
print("No network required. Press Ctrl+C to exit.")

try await Task.sleep(for: .seconds(3600))
