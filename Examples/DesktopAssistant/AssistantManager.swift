import Foundation
import AppKit
import StrandsAgents
import StrandsBedrockProvider
import StrandsBidiStreaming
import StrandsMLXBidiProvider
import MLXAudioSTT
import MLXAudioTTS

enum VoiceBackend: String, CaseIterable {
    case localMLX = "Local (On-Device)"
    case novaSonic = "Nova Sonic (Cloud)"
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

    /// Called by the manager to hide/show the popover during automation
    var onHidePopover: (() -> Void)?
    var onShowPopover: (() -> Void)?

    // MARK: - Private

    private var textAgent: Agent?
    private var bidiAgent: BidiAgent?
    private var mcpProvider: MCPToolProvider?
    private var tools: [any AgentTool] = []
    private var currentTask: Task<Void, Never>?
    private var micTask: Task<Void, Never>?
    private var microphone: MicrophoneInput?
    private var speaker: SpeakerOutput?

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

        // Hide the popover and deactivate the app so macOS gives focus to the desktop
        onHidePopover?()
        NSApp.hide(nil)

        currentTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second for focus to fully settle
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
            // Show the popover again so the user can see results
            onShowPopover?()
        }
    }

    // MARK: - Voice

    func toggleVoice() async {
        if isVoiceActive {
            await stopVoice()
            return
        }

        // Show immediate feedback
        statusMessage = "Connecting voice..."
        messages.append(AssistantMessage(role: "system", content: "Starting voice mode (\(voiceBackend.rawValue))..."))

        do {
            // Create the bidi model based on selected backend
            let bidi: BidiAgent
            let audioFormat: AudioFormat

            switch voiceBackend {
            case .localMLX:
                print("[Voice] Loading local MLX models (STT + LLM + TTS)...")
                statusMessage = "Loading models..."

                let sttModel = try await GLMASRModel.fromPretrained("mlx-community/GLM-ASR-Nano-2512-4bit")
                print("[Voice] STT model loaded")
                let ttsModel = try await SopranoModel.fromPretrained("mlx-community/Soprano-80M-bf16")
                print("[Voice] TTS model loaded")

                audioFormat = .mlxDefault
                bidi = MLXBidiFactory.createAgent(
                    llmProcessor: MLXLLMProcessor(modelId: "mlx-community/Qwen3-8B-4bit", maxTokens: 1024),
                    sttProcessor: MLXSTTProcessor(model: sttModel),
                    ttsProcessor: MLXTTSProcessor(model: ttsModel),
                    tools: tools,
                    systemPrompt: desktopSystemPrompt
                )

            case .novaSonic:
                print("[Voice] Creating NovaSonicModel...")
                messages.append(AssistantMessage(role: "system", content: "Note: Nova Sonic bidi streaming requires HTTP/2 support not yet available in the AWS SDK for Swift. This may time out."))
                let model = try NovaSonicModel(region: "us-east-1", voice: "tiffany")
                audioFormat = .novaSonic
                bidi = BidiAgent(
                    model: model,
                    tools: tools,
                    config: BidiSessionConfig(
                        instructions: desktopSystemPrompt,
                        voice: "tiffany",
                        inputAudioFormat: audioFormat,
                        outputAudioFormat: audioFormat
                    )
                )
            }

            bidiAgent = bidi

            // Set up microphone and speaker
            let mic = MicrophoneInput(format: audioFormat)
            let spk = SpeakerOutput(format: audioFormat)
            microphone = mic
            speaker = spk

            // Start the bidi session
            print("[Voice] Starting bidi session...")
            try await bidi.start()
            print("[Voice] Session started. Starting audio I/O...")
            try mic.start()
            try spk.start()
            print("[Voice] Audio I/O started.")

            isVoiceActive = true
            statusMessage = "Listening..."
            messages.append(AssistantMessage(role: "system", content: "Voice active. Speak your command. Click mic or press Escape to stop."))

            // Hide popover so voice automation can control the desktop
            onHidePopover?()
            NSApp.hide(nil)

            // Task 1: send mic audio to the model
            micTask = Task {
                for await chunk in mic.audioStream {
                    if Task.isCancelled { break }
                    try? await bidi.send(.audio(chunk, format: audioFormat))
                }
            }

            // Task 2: receive events from the model
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
            print("[Voice] Error: \(error)")
            messages.append(AssistantMessage(role: "system", content: "Voice failed: \(error.localizedDescription)"))
            statusMessage = isReady ? "Ready (\(tools.count) tools)" : "Error"
            onShowPopover?()
        }
    }

    private func handleBidiEvent(_ event: BidiOutputEvent) async {
        switch event {
        case .audio(let data, _):
            speaker?.play(data)

        case .transcript(let role, let text, let isFinal):
            if isFinal {
                messages.append(AssistantMessage(role: role == .user ? "user" : "assistant", content: text))
            }

        case .inputSpeechStarted:
            statusMessage = "Hearing you..."
            speaker?.interrupt()

        case .inputSpeechDone(let transcript):
            if !transcript.isEmpty {
                messages.append(AssistantMessage(role: "user", content: transcript))
            }
            statusMessage = "Thinking..."

        case .responseStarted:
            statusMessage = "Speaking..."

        case .responseDone:
            statusMessage = "Listening..."

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
        micTask?.cancel()
        micTask = nil
        microphone?.stop()
        microphone = nil
        speaker?.stop()
        speaker = nil
        await bidiAgent?.stop()
        bidiAgent = nil
        isVoiceActive = false
        statusMessage = isReady ? "Ready (\(tools.count) tools)" : "Error"
        onShowPopover?()
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
        onShowPopover?()
    }
}
