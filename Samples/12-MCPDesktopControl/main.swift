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
import StrandsMLXProvider
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Native screenshot tool (replaces broken MCP screenshot)

let screenshotTool = FunctionTool(
    name: "screenshot",
    description: "Take a screenshot of the entire screen and save it to /tmp. Returns the file path.",
    inputSchema: ["type": "object"]
) { (_: JSONValue, _: ToolContext) async throws -> String in
    let path = "/tmp/agent_screenshot_\(Int(Date().timeIntervalSince1970)).png"
    guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
        return "Error: could not capture screen. Check Screen Recording permission."
    }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        return "Error: could not create image file."
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        return "Error: could not write image."
    }
    let width = image.width
    let height = image.height
    return "Screenshot saved to \(path) (\(width)x\(height) pixels)"
}

// MARK: - MCP tools

let bunPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".bun/bin/bun").path

print("Starting Automation MCP server...")

let mcpProvider = MCPToolProvider(
    command: bunPath,
    arguments: ["run", "/tmp/automation-mcp/index.ts", "--stdio"]
)

// Filter out tools with upstream issues:
// - waitForImage: invalid JSON Schema that Bedrock rejects
// - screenshot: base64 encoding bug in the MCP server (replaced with native Swift tool above)
let allMcpTools = try await mcpProvider.loadTools()
let mcpTools = allMcpTools.filter { $0.name != "waitForImage" && $0.name != "screenshot" }

// Combine native screenshot + MCP tools
let tools: [any AgentTool] = [screenshotTool] + mcpTools

print("Loaded \(tools.count) tools (\(mcpTools.count) from MCP + 1 native screenshot):")
for tool in tools {
    print("  - \(tool.name)")
}
print()

// MARK: - Agent

let useLocal = ProcessInfo.processInfo.environment["USE_LOCAL"] != nil
let model: any ModelProvider = useLocal
    ? MLXProvider(modelId: "mlx-community/Qwen3-8B-4bit")
    : try BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
        region: "us-east-1"
    ))

print("Using \(useLocal ? "local MLX" : "cloud Bedrock") model\n")

let agent = Agent(
    model: model,
    tools: tools,
    systemPrompt: """
    You are a macOS desktop assistant. You control the user's Mac using the available tools.

    Your workflow for any task:
    1. Take a screenshot first to see what is on screen
    2. Use mouse clicks and keyboard input to interact with apps
    3. Take screenshots between steps to verify your progress
    4. If something goes wrong, take a screenshot to diagnose and retry

    You can open apps with Spotlight: press Command+Space via keyControl, type the app name, press Return.
    Use keyboard shortcuts: Cmd+S to save, Cmd+N for new document, Cmd+W to close, etc.
    Use systemCommand for common actions like copy, paste, undo, save.

    If you need information you don't have (like the user's email), ask before proceeding.
    Always confirm what you did after each step.
    """
)

// MARK: - Interactive loop

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
