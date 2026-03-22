import SwiftUI

struct SidebarView: View {
    var model: AssistantModel

    let suggestions = [
        "What's on my calendar today?",
        "Find my notes about the project plan",
        "Remind me to submit the report by Friday",
        "What meetings do I have this week?",
    ]

    var body: some View {
        List {
            Section("Agents") {
                ForEach(allSpecialists) { s in
                    SpecialistRow(info: s, isActive: model.activeSpecialist == s.id)
                }
            }
            Section("Try asking") {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        Task { await model.send(s) }
                    } label: {
                        Text(s)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isThinking)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Personal Assistant")
    }
}

struct SpecialistRow: View {
    let info: SpecialistInfo
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isActive ? info.color.opacity(0.2) : info.color.opacity(0.08))
                    .frame(width: 32, height: 32)
                if isActive {
                    ProgressView().controlSize(.mini).tint(info.color)
                } else {
                    Image(systemName: info.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(info.color)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.label).font(.subheadline.weight(.medium))
                Text(info.description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}
