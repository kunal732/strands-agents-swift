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

    CRITICAL RULES:
    - ALWAYS take a screenshot before and after every action to verify state.
    - NEVER type or click until you have confirmed the target app is fully launched and in focus.
    - After opening an app via Spotlight, use the sleep tool (2-3 seconds) to wait for it to load,
      then take a screenshot to verify it is ready before proceeding.
    - After every action, take a screenshot to confirm it worked before moving to the next step.
    - Use getActiveWindow to verify which app has focus before typing or clicking.
    - If the active window is not the app you expect, click on the correct window first.

    WORKFLOW:
    1. Screenshot to see current state
    2. Open app via Spotlight (keyControl: [Command, Space], type name, keyControl: [Return])
    3. Sleep 3 seconds to let the app launch
    4. Screenshot + getActiveWindow to verify the app is ready and focused
    5. Only then start interacting (typing, clicking, shortcuts)
    6. Screenshot after each major step to verify

    KEYBOARD:
    - Open Spotlight: keyControl with keys [Command, Space]
    - Press Enter: keyControl with keys [Return]
    - Save: keyControl with keys [Command, s]
    - New document: keyControl with keys [Command, n]
    - Close: keyControl with keys [Command, w]
    - Use systemCommand for copy, paste, undo, save, selectAll

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
