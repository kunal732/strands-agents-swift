import SwiftUI

struct AssistantView: View {
    @Bindable var manager: AssistantManager
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            inputBar
        }
        .frame(width: 480, height: 520)
        .background(.background)
        .onAppear { inputFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text("Desktop Assistant")
                .font(.headline)

            Spacer()

            Text(manager.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if manager.isLoading {
                Button { manager.cancelCurrentTask() } label: {
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
        if manager.isLoading    { return .yellow }
        if manager.isReady      { return .green }
        return .gray
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(manager.messages) { msg in
                        messageBubble(msg).id(msg.id)
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
            Image(systemName: iconForRole(msg.role))
                .font(.caption)
                .foregroundStyle(colorForRole(msg.role))
                .frame(width: 16)

            if msg.role == "tool" {
                Text(msg.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text(msg.content)
                    .font(.callout)
                    .foregroundStyle(msg.role == "system" ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func iconForRole(_ role: String) -> String {
        switch role {
        case "user":      return "person.fill"
        case "assistant": return "sparkles"
        case "tool":      return "wrench.fill"
        default:          return "info.circle"
        }
    }

    private func colorForRole(_ role: String) -> Color {
        switch role {
        case "user":      return .blue
        case "assistant": return .purple
        case "tool":      return .orange
        default:          return .gray
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Type a command...", text: $inputText)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { send() }
                .disabled(!manager.isReady || manager.isLoading)

            Button { send() } label: {
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
