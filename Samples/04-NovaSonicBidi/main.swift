// 04 - Nova Sonic Bidirectional Streaming
// Real-time voice agent using AWS Nova Sonic.
// Audio flows in from the microphone and out to the speaker simultaneously.
// Requires AWS credentials with Bedrock access.

import Foundation
import StrandsAgents
import StrandsBidiStreaming
import StrandsAgentsToolMacros

@Tool
func getCurrentTime(timezone: String = "local") -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: Date())
}

let agent = BidiAgent(
    model: try NovaSonicModel(
        region: "us-east-1",
        voice: "tiffany"
    ),
    tools: [getCurrentTime],
    config: BidiSessionConfig(
        instructions: "You are a friendly voice assistant. Keep responses short and conversational."
    )
)

print("Starting Nova Sonic voice agent...")
try await agent.start()

// In a real app, you'd connect a microphone and speaker:
//
// Task {
//     for await chunk in microphone.audioStream {
//         try await agent.send(.audio(chunk, format: .novaSonic))
//     }
// }
//
// for try await event in agent.receive() {
//     switch event {
//     case .audio(let data, _):
//         speaker.play(data)
//     case .transcript(let text):
//         print("Agent: \(text)")
//     default:
//         break
//     }
// }

print("Agent ready. Connect audio I/O to start a conversation.")
print("Press Ctrl+C to exit.")

// Keep the process alive
try await Task.sleep(for: .seconds(3600))
