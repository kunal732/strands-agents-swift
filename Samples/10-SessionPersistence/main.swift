// 10 - Session Persistence
// Conversation history survives app restarts using FileSessionStorage.
// Run this sample twice to see the agent remember your name from the first run.

import Foundation
import StrandsAgents

let sessionsDir = FileManager.default.temporaryDirectory.appendingPathComponent("strands-sessions")
try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

let storage = FileSessionStorage(directory: sessionsDir)
let manager = SessionManager(storage: storage, sessionId: "demo-session")

let agent = Agent(
    model: try BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
        region: "us-east-1"
    )),
    systemPrompt: "You are a helpful assistant. Remember details the user tells you.",
    sessionManager: manager
)

// Try to restore a previous session
let restored = try await agent.restoreSession()
print(restored ? "Restored previous session (\(agent.messages.count) messages)" : "Starting fresh session")
print("Session stored at: \(sessionsDir.path)\n")

if !restored {
    // First run: introduce yourself
    print("User: My name is Alex and I'm a Swift developer.\n")
    let result = try await agent.run("My name is Alex and I'm a Swift developer.")
    print("Agent: \(result.message.textContent ?? "")\n")

    print("User: I'm working on an AI agent SDK.\n")
    let result2 = try await agent.run("I'm working on an AI agent SDK.")
    print("Agent: \(result2.message.textContent ?? "")\n")

    print("--- Run this sample again to test persistence ---")
} else {
    // Second run: test recall
    print("User: What's my name and what am I working on?\n")
    let result = try await agent.run("What's my name and what am I working on?")
    print("Agent: \(result.message.textContent ?? "")\n")

    print("The agent remembered your details from the previous session.")
}
