import SwiftUI

struct ChatView: View {
    @Bindable var manager: AgentManager
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !manager.isModelLoaded {
                loadingView
            } else {
                messageList
                Divider()
                inputBar
            }
        }
        .frame(width: 480, height: 600)
        .task {
            if !manager.isModelLoaded {
                await manager.loadModel()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: manager.selectedBackend == .local ? "cpu" : "cloud")
                .foregroundStyle(.secondary)
            Text("Strands Agent")
                .font(.headline)
            Spacer()

            Picker("", selection: Binding(
                get: { manager.selectedBackend },
                set: { backend in Task { await manager.switchBackend(to: backend) } }
            )) {
                ForEach(ModelBackend.allCases, id: \.self) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Button(action: manager.clearConversation) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear conversation")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text(manager.modelLoadingStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(manager.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: manager.messages.count) {
                if let last = manager.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button(action: manager.toggleVoice) {
                Image(systemName: manager.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(manager.isRecording ? .red : .primary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(manager.isRecording ? "Stop recording" : "Start voice input")

            TextField("Message...", text: $inputText)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .onSubmit { send() }
                .disabled(manager.isLoading)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(inputText.isEmpty ? .secondary : .blue)
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || manager.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { isInputFocused = true }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task { await manager.sendMessage(text) }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBubble
        case .tool: toolBubble
        case .system: systemBubble
        case .thinking: thinkingBubble
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer()
            Text(message.content)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var assistantBubble: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.6)
                        Text("Generating...").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
    }

    private var thinkingBubble: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: message.isThinkingDone ? "brain" : "brain")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(message.isThinkingDone ? "Thought process" : "Thinking...")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                    Spacer()
                    if message.isStreaming {
                        ProgressView().scaleEffect(0.5)
                    }
                }

                if message.isThinkingDone {
                    // Collapsed by default, expandable
                    DisclosureGroup("Show reasoning") {
                        Text(message.content)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    // While streaming, show it live
                    Text(message.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 60)
        }
    }

    private var toolBubble: some View {
        HStack(spacing: 6) {
            Image(systemName: message.toolStatus == "success" ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(message.toolStatus == "success" ? .green : .red)
                .font(.caption)
            Text(message.toolName ?? "tool")
                .font(.caption)
                .fontWeight(.medium)
            Text(message.content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var systemBubble: some View {
        HStack {
            Spacer()
            Text(message.content)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
