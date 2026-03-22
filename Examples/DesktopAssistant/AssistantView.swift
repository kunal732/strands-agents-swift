import SwiftUI

struct AssistantView: View {
    @Bindable var manager: AssistantManager
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            // Messages
            messageList

            Divider()

            // Input bar
            inputBar
        }
        .frame(width: 480, height: 520)
        .background(.background)
        .onAppear { inputFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text("Desktop Assistant")
                .font(.headline)

            Spacer()

            Text(manager.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Voice backend picker
            Picker("", selection: $manager.voiceBackend) {
                ForEach(VoiceBackend.allCases, id: \.self) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            .controlSize(.small)

            // Cancel button
            if manager.isLoading || manager.isVoiceActive {
                Button {
                    manager.cancelCurrentTask()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Cancel (Escape)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        if manager.isCancelling { return .orange }
        if manager.isVoiceActive { return .red }
        if manager.isLoading { return .yellow }
        if manager.isReady { return .green }
        return .gray
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(manager.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
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

    private func messageBubble(_ msg: AssistantMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Icon
            Image(systemName: iconForRole(msg.role))
                .font(.caption)
                .foregroundStyle(colorForRole(msg.role))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                if msg.role == "tool" {
                    Text(msg.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(msg.content)
                        .font(.callout)
                        .foregroundStyle(msg.role == "system" ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }

    private func iconForRole(_ role: String) -> String {
        switch role {
        case "user":      return "person.fill"
        case "assistant": return "sparkles"
        case "tool":      return "wrench.fill"
        case "system":    return "info.circle"
        default:          return "circle"
        }
    }

    private func colorForRole(_ role: String) -> Color {
        switch role {
        case "user":      return .blue
        case "assistant": return .purple
        case "tool":      return .orange
        case "system":    return .gray
        default:          return .primary
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Mic button with Siri-like animation
            Button {
                Task { await manager.toggleVoice() }
            } label: {
                ZStack {
                    // Pulsing ring when voice is active
                    if manager.isVoiceActive {
                        Circle()
                            .stroke(Color.red.opacity(0.4), lineWidth: 3)
                            .frame(width: 32, height: 32)
                            .scaleEffect(manager.isVoiceActive ? 1.4 : 1.0)
                            .opacity(manager.isVoiceActive ? 0 : 1)
                            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false), value: manager.isVoiceActive)

                        Circle()
                            .fill(Color.red.opacity(0.15))
                            .frame(width: 30, height: 30)
                    }

                    Image(systemName: manager.isVoiceActive ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        .foregroundStyle(manager.isVoiceActive ? .red : .primary)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!manager.isReady || manager.isLoading)
            .help("Voice mode")

            // Text field
            TextField("Type a command...", text: $inputText)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { send() }
                .disabled(!manager.isReady || manager.isLoading || manager.isVoiceActive)

            // Send button
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || !manager.isReady || manager.isLoading)
        }
        .padding(12)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        manager.sendMessage(text)
    }
}
