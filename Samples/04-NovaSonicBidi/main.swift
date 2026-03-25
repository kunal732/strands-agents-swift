// 04 - Nova Sonic Bidirectional Streaming
// Real-time voice agent using AWS Nova Sonic.
// Audio flows in from the microphone and out to the speaker simultaneously.
// Requires AWS credentials with Bedrock access.

import Foundation
import StrandsAgents

func getCurrentTime(timezone: String = "local") -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: Date())
}
let getCurrentTimeTool = Tool(getCurrentTime, "Get the current time.", name: "get_current_time")

let agent = BidiAgent(
    model: try NovaSonicModel(
        region: "us-east-1",
        voice: "tiffany"
    ),
    tools: [getCurrentTimeTool],
    config: BidiSessionConfig(
        instructions: "You are a friendly voice assistant. Keep responses short and conversational."
    )
)

print("Starting Nova Sonic voice agent...")
try await agent.start()

print("Agent ready. Connect audio I/O to start a conversation.")
print("Press Ctrl+C to exit.")

try await Task.sleep(for: .seconds(3600))
