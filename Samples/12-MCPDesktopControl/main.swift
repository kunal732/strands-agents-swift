// 12 - MCP Desktop Control
// Gives the agent full control over your macOS desktop: mouse, keyboard,
// screenshots, and window management via the Automation MCP server.
//
// Prerequisites:
//   1. Install bun: curl -fsSL https://bun.sh/install | bash
//   2. Clone the MCP server:
//      git clone https://github.com/ashwwwin/automation-mcp.git /tmp/automation-mcp
//      cd /tmp/automation-mcp && bun install
//   3. Grant Accessibility and Screen Recording permissions when prompted
//
// The agent can follow complex multi-step instructions like:
//   "Create a document, write content, save it, then email it to me"

import Foundation
import StrandsAgents
import StrandsBedrockProvider

// Launch the Automation MCP server as a stdio subprocess
let bunPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".bun/bin/bun").path

print("Starting Automation MCP server...")

let mcpProvider = MCPToolProvider(
    command: bunPath,
    arguments: ["run", "/tmp/automation-mcp/index.ts", "--stdio"]
)
let mcpTools = try await mcpProvider.loadTools()

print("Loaded \(mcpTools.count) desktop tools:")
for tool in mcpTools {
    print("  - \(tool.name)")
}
print()

let agent = Agent(
    model: try BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
        region: "us-east-1"
    )),
    tools: mcpTools,
    systemPrompt: """
    You are a macOS desktop assistant. You control the user's Mac using the available \
    MCP tools: mouse clicks, keyboard input, screenshots, and window management.

    When executing multi-step tasks:
    1. Take a screenshot first to see what's on screen
    2. Use mouse clicks and keyboard input to interact with apps
    3. Take screenshots between steps to verify your progress
    4. If something goes wrong, take a screenshot to diagnose and retry

    If you need information you don't have (like the user's email address), ask them \
    before proceeding. Always confirm what you did after each step.

    You can open apps with Spotlight: use Cmd+Space, type the app name, then press Enter.
    You can use keyboard shortcuts: Cmd+S to save, Cmd+N for new document, Cmd+W to close, etc.
    """
)

// Interactive mode: the user tells the agent what to do
print("Desktop agent ready. Tell it what to do on your Mac.")
print("Example: \"Create a new TextEdit document about Swift agents and save it to Desktop\"")
print("Type 'quit' to exit.\n")

print("> ", terminator: "")
while let line = readLine(), line.lowercased() != "quit" {
    print()
    for try await event in agent.stream(line) {
        switch event {
        case .textDelta(let token):
            print(token, terminator: "")
        case .toolResult(let result):
            let text = result.content.compactMap {
                if case .text(let t) = $0 { return t } else { return nil }
            }.joined()
            let preview = text.prefix(200)
            print("\n  [Tool result: \(preview)]\n")
        default:
            break
        }
    }
    print("\n\n> ", terminator: "")
}
