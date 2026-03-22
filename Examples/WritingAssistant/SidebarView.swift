import SwiftUI

struct SidebarView: View {
    var model: WritingModel
    @Binding var selectedAgent: String?

    var body: some View {
        List(selection: $selectedAgent) {
            Section("Agent Pipeline") {
                ForEach(model.agents) { agent in
                    AgentRow(agent: agent)
                        .tag(agent.id)
                }
            }
            Section("How it works") {
                Text("Grammar, Tone, and Clarity agents run in parallel. The Editor synthesizes their findings into the top improvements.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Writing Assistant")
    }
}

struct AgentRow: View {
    let agent: AgentResult

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(agent.color.opacity(0.12))
                    .frame(width: 32, height: 32)
                switch agent.status {
                case .idle:
                    Image(systemName: agent.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(agent.color.opacity(0.5))
                case .running:
                    ProgressView().controlSize(.small).tint(agent.color)
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(agent.color)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.label).font(.subheadline.weight(.medium))
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if agent.status == .done && !agent.output.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.3), value: agent.status)
    }

    private var statusLabel: String {
        switch agent.status {
        case .idle:    return agent.id == "editor" ? "Waits for others" : "Waiting"
        case .running: return "Analyzing..."
        case .done:    return agent.output.isEmpty ? "Done" : "Tap to view feedback"
        }
    }
}
