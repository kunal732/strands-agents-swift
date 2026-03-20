// 12 - MCP Desktop Control
// Connects to the UltraMac MCP server to give the agent control over
// macOS desktop actions: mouse, keyboard, screenshots, app management.
//
// Requires the UltraMac MCP server running locally:
//   git clone https://github.com/jxoesneon/ultramac-mcp
//   cd ultramac-mcp && npm install && npm start
//
// The server exposes tools like move_mouse, click, type_text, take_screenshot,
// open_application, and more via the Model Context Protocol.

import Foundation
import StrandsAgents
import StrandsBedrockProvider

print("Connecting to UltraMac MCP server...")

let mcpProvider = MCPToolProvider(
    command: "npx",
    arguments: ["-y", "ultramac-mcp"]
)
let mcpTools = try await mcpProvider.loadTools()

print("Loaded \(mcpTools.count) desktop control tools from UltraMac MCP:")
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
    You are a desktop assistant with control over the user's macOS desktop via MCP tools.
    You can move the mouse, click, type text, take screenshots, open applications, and more.
    When the user asks you to do something on the desktop, use the available tools to accomplish it.
    Always confirm what you did after completing an action.
    """
)

// Example 1: Open an application
print("User: Open TextEdit\n")
let result1 = try await agent.run("Open TextEdit")
print("Agent: \(result1.message.textContent ?? "")\n")

// Example 2: Type some text
print("User: Type 'Hello from Strands Agents!' in the open window\n")
let result2 = try await agent.run("Type 'Hello from Strands Agents!' in the open window")
print("Agent: \(result2.message.textContent ?? "")\n")

// Example 3: Take a screenshot
print("User: Take a screenshot of the current screen\n")
let result3 = try await agent.run("Take a screenshot of the current screen")
print("Agent: \(result3.message.textContent ?? "")\n")

// Interactive mode
print("--- Interactive mode (type 'quit' to exit) ---\n")
while let line = readLine(), line != "quit" {
    let result = try await agent.run(line)
    print("Agent: \(result.message.textContent ?? "")\n")
}
