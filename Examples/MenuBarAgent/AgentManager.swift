import Foundation
import StrandsAgents
import StrandsMLXProvider
import StrandsBedrockProvider
import Speech
import AVFoundation

@Observable
@MainActor
final class AgentManager {
    var messages: [ChatMessage] = []
    var isLoading = false
    var isModelLoaded = false
    var modelLoadingStatus = "Select a backend..."
    var isRecording = false
    var selectedBackend: ModelBackend = .bedrock

    private var agent: Agent?
    private let mlxModelId = "mlx-community/Qwen3-8B-4bit"
    private let bedrockModelId = "us.anthropic.claude-sonnet-4-20250514-v1:0"

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Model Loading

    func loadModel() async {
        isModelLoaded = false
        agent = nil

        switch selectedBackend {
        case .local: await loadMLX()
        case .bedrock: await loadBedrock()
        }
    }

    private func loadMLX() async {
        modelLoadingStatus = "Downloading \(mlxModelId)..."
        let provider = MLXProvider(config: MLXConfig(modelId: mlxModelId, maxTokens: 512, temperature: 0.7))
        modelLoadingStatus = "Loading into memory..."
        do {
            try await provider.preload()
        } catch {
            modelLoadingStatus = "Failed: \(error.localizedDescription)"
            return
        }
        agent = Agent(model: provider, tools: demoTools, systemPrompt: "You are a helpful assistant. Keep responses concise.")
        isModelLoaded = true
        modelLoadingStatus = "MLX Ready"
        messages.append(ChatMessage(role: .system, content: "Local model loaded (\(mlxModelId))"))
    }

    private func loadBedrock() async {
        modelLoadingStatus = "Connecting to Bedrock..."
        do {
            // Uses AWS credential chain: Cognito via Amplify, env vars, ~/.aws/credentials, or IAM role
            let provider = try BedrockProvider(config: BedrockConfig(modelId: bedrockModelId, region: "us-east-1", maxTokens: 1024))
            agent = Agent(model: provider, tools: demoTools, systemPrompt: "You are a helpful assistant. Keep responses concise.")
            isModelLoaded = true
            modelLoadingStatus = "Bedrock Ready"
            messages.append(ChatMessage(role: .system, content: "Connected to Bedrock (Claude Sonnet 4)"))
        } catch {
            modelLoadingStatus = "Failed: \(error.localizedDescription)"
        }
    }

    func switchBackend(to backend: ModelBackend) async {
        guard backend != selectedBackend || !isModelLoaded else { return }
        selectedBackend = backend
        messages.removeAll()
        agent?.resetConversation()
        await loadModel()
    }

    // MARK: - Send Message

    func sendMessage(_ text: String) async {
        guard let agent, !text.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: text))
        isLoading = true

        var thinkingContent = ""
        var isInThinkBlock = false
        var thinkingIndex: Int? = nil
        var responseContent = ""
        var responseIndex: Int? = nil

        do {
            for try await event in agent.stream(text) {
                switch event {
                case .textDelta(let delta):
                    let buffer = (isInThinkBlock ? thinkingContent : responseContent) + delta

                    // Detect <think> start
                    if !isInThinkBlock && buffer.contains("<think>") {
                        isInThinkBlock = true
                        thinkingContent = buffer.components(separatedBy: "<think>").last ?? ""
                        thinkingIndex = messages.count
                        messages.append(ChatMessage(role: .thinking, content: thinkingContent, isStreaming: true))
                        continue
                    }

                    if isInThinkBlock {
                        if buffer.contains("</think>") {
                            // Thinking done
                            isInThinkBlock = false
                            thinkingContent = buffer.components(separatedBy: "</think>").first ?? ""
                            if let idx = thinkingIndex {
                                messages[idx].content = thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines)
                                messages[idx].isStreaming = false
                                messages[idx].isThinkingDone = true
                            }
                            let remainder = buffer.components(separatedBy: "</think>").dropFirst().joined()
                            responseContent = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !responseContent.isEmpty {
                                responseIndex = messages.count
                                messages.append(ChatMessage(role: .assistant, content: responseContent, isStreaming: true))
                            }
                        } else {
                            thinkingContent += delta
                            if let idx = thinkingIndex { messages[idx].content = thinkingContent }
                        }
                    } else {
                        if responseIndex == nil {
                            responseIndex = messages.count
                            messages.append(ChatMessage(role: .assistant, content: "", isStreaming: true))
                        }
                        responseContent += delta
                        if let idx = responseIndex { messages[idx].content = responseContent }
                    }

                case .toolResult(let result):
                    let content = result.content.compactMap { c -> String? in
                        if case .text(let t) = c { return t }
                        return nil
                    }.joined()
                    let toolName = agent.messages.flatMap(\.toolUses)
                        .last(where: { $0.toolUseId == result.toolUseId })?.name ?? "tool"
                    messages.append(ChatMessage(role: .tool, content: content, toolName: toolName,
                                                toolStatus: result.status == .success ? "success" : "error"))

                case .result:
                    if let idx = responseIndex {
                        messages[idx].isStreaming = false
                        messages[idx].content = messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let idx = thinkingIndex {
                        messages[idx].isStreaming = false
                        messages[idx].isThinkingDone = true
                    }

                default: break
                }
            }
        } catch {
            messages.append(ChatMessage(role: .system, content: "Error: \(error.localizedDescription)"))
        }

        isLoading = false
    }

    // MARK: - Voice

    func toggleVoice() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            Task { @MainActor in self?.beginAudioCapture() }
        }
    }

    private func beginAudioCapture() {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    Task { @MainActor in
                        self.stopRecording()
                        if !text.isEmpty {
                            await self.sendMessage(text)
                            if let last = self.messages.last(where: { $0.role == .assistant }) {
                                self.speak(last.content)
                            }
                        }
                    }
                }
                if error != nil { Task { @MainActor in self.stopRecording() } }
            }
        } catch { stopRecording() }
    }

    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func clearConversation() {
        messages.removeAll()
        agent?.resetConversation()
        messages.append(ChatMessage(role: .system, content: "Conversation cleared."))
    }
}
