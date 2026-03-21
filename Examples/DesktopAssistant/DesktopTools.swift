import Foundation
import StrandsAgents
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Native screenshot tool

let screenshotTool = FunctionTool(
    name: "screenshot",
    description: "Take a screenshot of the entire screen and save it to /tmp. Returns the file path and dimensions.",
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
    return "Screenshot saved to \(path) (\(image.width)x\(image.height) pixels)"
}

// MARK: - MCP tool loading

struct DesktopToolKit {
    let mcpProvider: MCPToolProvider
    let tools: [any AgentTool]
}

func loadDesktopTools() async throws -> DesktopToolKit {
    let bunPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".bun/bin/bun").path

    let mcpProvider = MCPToolProvider(
        command: bunPath,
        arguments: ["run", "/tmp/automation-mcp/index.ts", "--stdio"]
    )

    let allMcpTools = try await mcpProvider.loadTools()
    let mcpTools = allMcpTools.filter { $0.name != "waitForImage" && $0.name != "screenshot" }

    let tools: [any AgentTool] = [screenshotTool] + mcpTools
    return DesktopToolKit(mcpProvider: mcpProvider, tools: tools)
}

// MARK: - System prompt

let desktopSystemPrompt = """
You are a macOS desktop assistant. You control the user's Mac using the available tools.

CRITICAL RULES:
- ALWAYS take a screenshot before and after every action to verify state.
- NEVER type or click until you have confirmed the target app is fully launched and in focus.
- After opening an app via Spotlight, use the sleep tool (2-3 seconds) to wait for it to load, \
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

KEYBOARD (use keyControl with these key names):
- Open Spotlight: keys [Command, Space]
- Press Enter: keys [Return]
- Save: keys [Command, s]
- New document: keys [Command, n]
- Close window: keys [Command, w]
- Select all: keys [Command, a]
- Use systemCommand for copy, paste, undo

APP LAUNCH TIPS:
- After opening any app via Spotlight, ALWAYS press Command+n to create a new document.
- Microsoft Word opens to a template gallery. Press Command+n immediately after it launches.
- Google Chrome/Safari: Command+n for new window, Command+l to focus the address bar.
- When getActiveWindow returns an empty title "", the app is still loading. Sleep and retry.

If you need information you don't have (like the user's email), ask before proceeding.
Always confirm what you did after each step.
"""
