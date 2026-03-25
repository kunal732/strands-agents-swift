import Foundation
import AppKit
import StrandsAgents

private func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    let path = "/tmp/desktop_assistant_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

struct AssistantMessage: Identifiable {
    let id = UUID()
    let role: String       // "user", "assistant", "tool", "system"
    var content: String
    let timestamp = Date()
    var isStreaming = false
}

@Observable
@MainActor
final class AssistantManager {
    // MARK: - Published state

    var messages: [AssistantMessage] = []
    var isLoading = false
    var isCancelling = false
    var statusMessage = "Starting..."
    var isReady = false

    /// Called by the manager to hide/show the popover during automation
    var onHidePopover: (() -> Void)?
    var onShowPopover: (() -> Void)?

    // MARK: - Private

    private var textAgent: Agent?
    private var mcpProvider: MCPToolProvider?
    private var tools: [any AgentTool] = []
    private var currentTask: Task<Void, Never>?

    // MARK: - Setup

    func setup() async {
        statusMessage = "Loading MCP tools..."
        do {
            let toolkit = try await loadDesktopTools()
            mcpProvider = toolkit.mcpProvider
            tools = toolkit.tools
            statusMessage = "Creating agent..."

            let provider = try BedrockProvider(config: BedrockConfig(
                modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
                region: "us-east-1"
            ))

            textAgent = Agent(
                model: provider,
                tools: tools,
                systemPrompt: desktopSystemPrompt
            )

            isReady = true
            statusMessage = "Ready (\(tools.count) tools)"
            messages.append(AssistantMessage(
                role: "system",
                content: "Desktop assistant ready with \(tools.count) tools. Type a command."
            ))
        } catch {
            statusMessage = "Setup failed: \(error.localizedDescription)"
            messages.append(AssistantMessage(role: "system", content: "Error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Text commands

    func sendMessage(_ text: String) {
        guard !text.isEmpty, isReady, !isLoading else { return }

        messages.append(AssistantMessage(role: "user", content: text))
        isLoading = true
        statusMessage = "Thinking..."

        let agent = textAgent!
        var assistantIdx: Int?

        onHidePopover?()
        NSApp.hide(nil)

        currentTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            do {
                for try await event in agent.stream(text) {
                    if Task.isCancelled { break }

                    switch event {
                    case .textDelta(let token):
                        if let idx = assistantIdx {
                            messages[idx].content += token
                        } else {
                            messages.append(AssistantMessage(role: "assistant", content: token, isStreaming: true))
                            assistantIdx = messages.count - 1
                        }

                    case .toolResult(let result):
                        let text = result.content.compactMap {
                            if case .text(let t) = $0 { return t } else { return nil }
                        }.joined()
                        messages.append(AssistantMessage(role: "tool", content: String(text.prefix(150))))
                        statusMessage = "Executing tools..."

                    case .result:
                        if let idx = assistantIdx {
                            messages[idx].isStreaming = false
                        }

                    default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    messages.append(AssistantMessage(role: "system", content: "Error: \(error.localizedDescription)"))
                }
            }

            isLoading = false
            currentTask = nil
            statusMessage = isReady ? "Ready (\(tools.count) tools)" : "Error"
            onShowPopover?()
        }
    }

    // MARK: - Cancellation

    func cancelCurrentTask() {
        guard isLoading else { return }
        isCancelling = true
        statusMessage = "Cancelling..."

        currentTask?.cancel()
        currentTask = nil

        messages.append(AssistantMessage(role: "system", content: "Cancelled."))
        isLoading = false
        isCancelling = false
        statusMessage = isReady ? "Ready (\(tools.count) tools)" : "Error"
        onShowPopover?()
    }
}
