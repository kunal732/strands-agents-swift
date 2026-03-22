// Personal Assistant
// Multi-agent swarm demo: a coordinator routes requests to specialist
// agents (calendar, notes, tasks). Shows which agent handled each reply.

import SwiftUI
import StrandsAgents
import StrandsBedrockProvider

// MARK: - Model

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
    let specialist: String?
    let timestamp = Date()
}

struct SpecialistInfo {
    let id: String
    let label: String
    let icon: String
    let color: Color
    let description: String
}

let specialists: [SpecialistInfo] = [
    SpecialistInfo(id: "coordinator",    label: "Coordinator",  icon: "arrow.triangle.branch", color: .gray,   description: "Routes requests"),
    SpecialistInfo(id: "calendar-agent", label: "Calendar",     icon: "calendar",              color: .blue,   description: "Meetings & events"),
    SpecialistInfo(id: "notes-agent",    label: "Notes",        icon: "note.text",             color: .orange, description: "Documents & search"),
    SpecialistInfo(id: "tasks-agent",    label: "Tasks",        icon: "checkmark.circle",      color: .green,  description: "Reminders & to-dos"),
]

@Observable @MainActor
final class AssistantModel {
    var messages: [ChatMessage] = []
    var activeSpecialist: String? = nil
    var isThinking = false

    @Tool nonisolated static func checkCalendar(date: String) -> String {
        "Calendar for \(date): 10am Team standup, 2pm Design review, 4pm 1:1 with manager"
    }
    @Tool nonisolated static func searchNotes(query: String) -> String {
        "Found 3 notes matching '\(query)': Meeting notes from Monday, Project plan draft, Weekly goals"
    }
    @Tool nonisolated static func createReminder(title: String, dueDate: String) -> String {
        "Reminder created: '\(title)' due \(dueDate)"
    }

    private let swarm: SwarmOrchestrator

    init() {
        let p = try! BedrockProvider(config: BedrockConfig(
            modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
            region: "us-east-1"
        ))

        swarm = SwarmOrchestrator(members: [
            SwarmMember(id: "coordinator",
                description: "Routes requests to the right specialist",
                agent: Agent(model: p, systemPrompt: """
                    You are a personal assistant coordinator. Hand off immediately:
                    - "calendar-agent": schedule, events, meetings, availability, calendar
                    - "notes-agent": notes, documents, search, find information
                    - "tasks-agent": reminders, tasks, to-do, deadlines
                    Do not answer yourself. Route only.
                    """)),
            SwarmMember(id: "calendar-agent",
                description: "Calendar and scheduling",
                agent: Agent(model: p, tools: [checkCalendar],
                    systemPrompt: "You manage the user's calendar. Use checkCalendar and answer helpfully and concisely.")),
            SwarmMember(id: "notes-agent",
                description: "Notes and documents",
                agent: Agent(model: p, tools: [searchNotes],
                    systemPrompt: "You manage notes and documents. Use searchNotes and answer helpfully and concisely.")),
            SwarmMember(id: "tasks-agent",
                description: "Reminders and tasks",
                agent: Agent(model: p, tools: [createReminder],
                    systemPrompt: "You manage reminders and tasks. Use createReminder and confirm what was created.")),
        ], entryPoint: "coordinator")
    }

    func send(_ text: String) async {
        guard !text.isEmpty, !isThinking else { return }
        messages.append(ChatMessage(role: "user", content: text, specialist: nil))
        isThinking = true
        activeSpecialist = "coordinator"

        do {
            let result = try await swarm.run(text)
            let specialist = result.executionOrder.last(where: { $0 != "coordinator" }) ?? "coordinator"
            activeSpecialist = specialist
            let reply = result.finalResult?.message.textContent ?? ""
            messages.append(ChatMessage(role: "assistant", content: reply, specialist: specialist))
        } catch {
            messages.append(ChatMessage(role: "assistant", content: "Error: \(error.localizedDescription)", specialist: nil))
        }

        isThinking = false
        activeSpecialist = nil
    }

    func clear() {
        messages.removeAll()
        activeSpecialist = nil
        isThinking = false
    }
}

// MARK: - App

@main
struct PersonalAssistantApp: App {
    var body: some Scene {
        WindowGroup("Personal Assistant") {
            RootView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 900, height: 640)
    }
}

// MARK: - Root layout

struct RootView: View {
    @State private var model = AssistantModel()
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } detail: {
            chatPane
        }
        .toolbar {
            ToolbarItem {
                Button { model.clear() } label: {
                    Label("Clear Chat", systemImage: "trash")
                }
                .disabled(model.messages.isEmpty || model.isThinking)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List {
            Section("Agents") {
                ForEach(specialists, id: \.id) { s in
                    SpecialistRow(info: s, isActive: model.activeSpecialist == s.id)
                }
            }

            Section("Try asking") {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        input = s
                        Task { await sendInput() }
                    } label: {
                        Label(s, systemImage: "arrow.up.right.square")
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isThinking)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Personal Assistant")
    }

    private let suggestions = [
        "What's on my calendar today?",
        "Find my notes about the project plan",
        "Remind me to submit the report by Friday",
        "What meetings do I have this week?",
    ]

    // MARK: Chat pane

    private var chatPane: some View {
        VStack(spacing: 0) {
            // Routing indicator
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
                    description: Text("Ask about your calendar, notes, or tasks.\nThe coordinator will route your request to the right agent.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
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
                    .onSubmit { Task { await sendInput() } }
                    .disabled(model.isThinking)

                Button {
                    Task { await sendInput() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(input.trimmingCharacters(in: .whitespaces).isEmpty || model.isThinking ? Color.secondary : Color.blue)
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

    private func sendInput() async {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        input = ""
        await model.send(t)
    }
}

// MARK: - Sidebar specialist row

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

// MARK: - Message bubble

struct MessageBubble: View {
    let msg: ChatMessage

    private var info: SpecialistInfo? {
        specialists.first(where: { $0.id == msg.specialist })
    }

    var body: some View {
        if msg.role == "user" {
            HStack {
                Spacer(minLength: 80)
                Text(msg.content)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: 420, alignment: .trailing)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                // Agent avatar
                ZStack {
                    Circle()
                        .fill((info?.color ?? .gray).opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: info?.icon ?? "sparkles")
                        .font(.system(size: 14))
                        .foregroundStyle(info?.color ?? .gray)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let info {
                        Text(info.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(info.color)
                    }
                    Text(msg.content)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: 460, alignment: .leading)
                }
                Spacer(minLength: 60)
            }
        }
    }
}
