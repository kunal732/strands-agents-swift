import Foundation
import StrandsAgents
import StrandsBedrockProvider
import StrandsBidiStreaming

enum VoiceBackend: String, CaseIterable {
    case novaSonic = "Nova Sonic (Cloud)"
    case localMLX = "Local MLX (On-Device)"
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
    var isVoiceActive = false
    var isCancelling = false
    var statusMessage = "Starting..."
    var isReady = false
    var voiceBackend: VoiceBackend = .novaSonic

    // MARK: - Private

    private var textAgent: Agent?
    private var bidiAgent: BidiAgent?
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
                content: "Desktop assistant ready with \(tools.count) tools. Type a command or click the mic."
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

        currentTask = Task {
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
                        let preview = String(text.prefix(150))
                        messages.append(AssistantMessage(role: "tool", content: preview))
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
        }
    }

    // MARK: - Voice

    func toggleVoice() async {
        if isVoiceActive {
            await stopVoice()
            return
        }

        do {
            let bidi: BidiAgent
            switch voiceBackend {
            case .novaSonic:
                let model = try NovaSonicModel(region: "us-east-1", voice: "tiffany")
                bidi = BidiAgent(
                    model: model,
                    tools: tools,
                    config: BidiSessionConfig(instructions: desktopSystemPrompt)
                )
            case .localMLX:
                // Local MLX bidi requires models to be loaded separately
                // For now, fall back to Nova Sonic with a note
                messages.append(AssistantMessage(role: "system", content: "Local MLX voice requires Xcode. Using Nova Sonic."))
                let model = try NovaSonicModel(region: "us-east-1", voice: "tiffany")
                bidi = BidiAgent(
                    model: model,
                    tools: tools,
                    config: BidiSessionConfig(instructions: desktopSystemPrompt)
                )
            }

            bidiAgent = bidi
            try await bidi.start()
            isVoiceActive = true
            statusMessage = "Listening..."
            messages.append(AssistantMessage(role: "system", content: "Voice mode active. Speak your command."))

            // Start receiving events
            currentTask = Task {
                do {
                    for try await event in bidi.receive() {
                        if Task.isCancelled { break }
                        await handleBidiEvent(event)
                    }
                } catch {
                    if !Task.isCancelled {
                        messages.append(AssistantMessage(role: "system", content: "Voice error: \(error.localizedDescription)"))
                    }
                }
                await stopVoice()
            }
        } catch {
            messages.append(AssistantMessage(role: "system", content: "Voice failed: \(error.localizedDescription)"))
        }
    }

    private func handleBidiEvent(_ event: BidiOutputEvent) async {
        switch event {
        case .transcript(let role, let text, let isFinal):
            if isFinal {
                messages.append(AssistantMessage(role: role == .user ? "user" : "assistant", content: text))
            }
        case .toolCall(let toolUse):
            messages.append(AssistantMessage(role: "tool", content: "Calling \(toolUse.name)..."))
            statusMessage = "Executing \(toolUse.name)..."
        case .toolResult(let result):
            let text = result.content.compactMap {
                if case .text(let t) = $0 { return t } else { return nil }
            }.joined()
            messages.append(AssistantMessage(role: "tool", content: String(text.prefix(150))))
        case .textDelta(let text):
            if let last = messages.last, last.role == "assistant", last.isStreaming {
                messages[messages.count - 1].content += text
            } else {
                messages.append(AssistantMessage(role: "assistant", content: text, isStreaming: true))
            }
        case .sessionEnded:
            messages.append(AssistantMessage(role: "system", content: "Voice session ended."))
        case .error(let msg):
            messages.append(AssistantMessage(role: "system", content: "Voice error: \(msg)"))
        default:
            break
        }
    }

    private func stopVoice() async {
        await bidiAgent?.stop()
        bidiAgent = nil
        isVoiceActive = false
        statusMessage = isReady ? "Ready (\(tools.count) tools)" : "Error"
    }

    // MARK: - Cancellation

    func cancelCurrentTask() {
        guard isLoading || isVoiceActive else { return }
        isCancelling = true
        statusMessage = "Cancelling..."

        currentTask?.cancel()
        currentTask = nil

        if isVoiceActive {
            Task { await stopVoice() }
        }

        messages.append(AssistantMessage(role: "system", content: "Cancelled."))
        isLoading = false
        isCancelling = false
        statusMessage = isReady ? "Ready (\(tools.count) tools)" : "Error"
    }
}
