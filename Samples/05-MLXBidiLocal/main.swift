// 05 - MLX Bidirectional Streaming (Fully Local)
// Voice agent running entirely on Apple Silicon.
// STT, LLM, and TTS all on-device. No network required after model download.
//
// Run via Xcode (Metal library loading fails with swift run).

import Foundation
import StrandsAgents
import MLXAudioSTT
import MLXAudioTTS

func getCurrentTime(timezone: String = "local") -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: Date())
}
let getCurrentTimeTool = Tool(getCurrentTime, "Get the current time.", name: "get_current_time")

print("Loading local voice models (STT + LLM + TTS)...")

let sttModel = try await GLMASRModel.fromPretrained("mlx-community/GLM-ASR-Nano-2512-4bit")
let ttsModel = try await SopranoModel.fromPretrained("mlx-community/Soprano-80M-bf16")

let agent = MLXBidiFactory.createAgent(
    llmProcessor: MLXLLMProcessor(),
    sttProcessor: MLXSTTProcessor(model: sttModel),
    ttsProcessor: MLXTTSProcessor(model: ttsModel),
    tools: [getCurrentTimeTool],
    systemPrompt: "You are a helpful on-device voice assistant. Keep responses short."
)

print("Local voice agent ready.")
try await agent.start()

print("Connect audio I/O to start a conversation.")
print("No network required. Press Ctrl+C to exit.")
try await Task.sleep(for: .seconds(3600))
