import SwiftUI

struct ChatView: View {
    var model: AssistantModel
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Routing status bar
            if model.isThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(routingLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
            }

            // Messages
            if model.messages.isEmpty {
                ContentUnavailableView(
                    "Personal Assistant",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Ask about your calendar, notes, or tasks.\nThe coordinator routes your request to the right specialist.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.messages) { msg in
                                MessageBubble(msg: msg).id(msg.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: model.messages.count) {
                        if let last = model.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 10) {
                TextField("Ask about your calendar, notes, or tasks...", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { send() }
                    .disabled(model.isThinking)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            input.trimmingCharacters(in: .whitespaces).isEmpty || model.isThinking
                                ? Color.secondary : Color.blue
                        )
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.isThinking)
            }
            .padding(14)
        }
        .onAppear { focused = true }
    }

    private var routingLabel: String {
        switch model.activeSpecialist {
        case "coordinator":    return "Routing your request..."
        case "calendar-agent": return "Calendar agent is responding..."
        case "notes-agent":    return "Notes agent is responding..."
        case "tasks-agent":    return "Tasks agent is responding..."
        default:               return "Thinking..."
        }
    }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        input = ""
        Task { await model.send(t) }
    }
}
