// Personal Assistant -- Multi-Agent Swarm Demo
//
// A coordinator agent routes requests to on-device specialists
// (calendar, notes, tasks). Shows which agent handled each request.
// Demonstrates SwarmOrchestrator with dynamic handoffs.

import SwiftUI
import StrandsAgents
import StrandsBedrockProvider

// MARK: - Message model

struct Message: Identifiable {
    let id = UUID()
    let role: String        // "user", "assistant"
    let content: String
    let agent: String?      // which specialist handled it
}

// MARK: - Swarm model

@Observable @MainActor
final class PersonalAssistantModel {
    var messages: [Message] = []
    var isLoading = false

    // Simulated on-device data
    @Tool nonisolated static func checkCalendar(date: String) -> String {
        "Calendar for \(date): 10am Team standup, 2pm Design review, 4pm 1:1 with manager"
    }
    @Tool nonisolated static func searchNotes(query: String) -> String {
        "Found 3 notes matching '\(query)': Meeting notes from Monday, Project plan draft, Weekly goals"
    }
    @Tool nonisolated static func createReminder(title: String, dueDate: String) -> String {
        "Created reminder: '\(title)' due \(dueDate)"
    }

    private let swarm: SwarmOrchestrator

    init() {
        let p = try! BedrockProvider(config: BedrockConfig(
            modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
            region: "us-east-1"
        ))

        let coordinator = Agent(model: p, systemPrompt: """
            You are a personal assistant coordinator. Route requests to the right specialist:
            - "calendar-agent": schedule, events, meetings, availability
            - "notes-agent": notes, documents, information
            - "tasks-agent": reminders, tasks, to-do items
            Hand off immediately. Do not answer yourself.
            """)

        let calendarAgent = Agent(model: p,
            tools: [checkCalendar],
            systemPrompt: "You manage the user's calendar. Use the checkCalendar tool and answer concisely.")

        let notesAgent = Agent(model: p,
            tools: [searchNotes],
            systemPrompt: "You manage the user's notes. Use the searchNotes tool and answer concisely.")

        let tasksAgent = Agent(model: p,
            tools: [createReminder],
            systemPrompt: "You manage reminders. Use the createReminder tool and confirm what was created.")

        swarm = SwarmOrchestrator(
            members: [
                SwarmMember(id: "coordinator",    description: "Routes requests",           agent: coordinator),
                SwarmMember(id: "calendar-agent", description: "Calendar and scheduling",   agent: calendarAgent),
                SwarmMember(id: "notes-agent",    description: "Notes and documents",       agent: notesAgent),
                SwarmMember(id: "tasks-agent",    description: "Reminders and tasks",       agent: tasksAgent),
            ],
            entryPoint: "coordinator"
        )
    }

    func send(_ text: String) async {
        guard !text.isEmpty, !isLoading else { return }
        messages.append(Message(role: "user", content: text, agent: nil))
        isLoading = true

        do {
            let result = try await swarm.run(text)
            let specialist = result.executionOrder.last(where: { $0 != "coordinator" }) ?? "coordinator"
            let reply = result.finalResult?.message.textContent ?? ""
            messages.append(Message(role: "assistant", content: reply, agent: specialist))
        } catch {
            messages.append(Message(role: "assistant", content: "Error: \(error.localizedDescription)", agent: nil))
        }

        isLoading = false
    }
}

// MARK: - App Entry

@main
struct PersonalAssistantApp: App {
    var body: some Scene {
        WindowGroup("Personal Assistant") {
            AssistantView()
                .frame(minWidth: 500, minHeight: 550)
        }
    }
}

// MARK: - UI

struct AssistantView: View {
    @State private var model = PersonalAssistantModel()
    @State private var input = ""
    @FocusState private var focused: Bool

    let suggestions = [
        "What's on my calendar today?",
        "Find my notes about the project plan",
        "Remind me to submit the report by Friday",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Personal Assistant")
                    .font(.largeTitle.bold())
                Text("A coordinator routes your request to the right specialist agent.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.messages.isEmpty {
                            VStack(spacing: 8) {
                                Text("Try one of these:")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 20)
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) {
                                        Task { await model.send(s) }
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }

                        ForEach(model.messages) { msg in
                            MessageRow(msg: msg).id(msg.id)
                        }

                        if model.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Routing to specialist...").foregroundStyle(.secondary).font(.caption)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Input
            HStack(spacing: 10) {
                TextField("Ask something...", text: $input)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { send() }
                    .disabled(model.isLoading)
                Button("Send") { send() }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.isLoading)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .onAppear { focused = true }
    }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        input = ""
        Task { await model.send(t) }
    }
}

struct MessageRow: View {
    let msg: Message

    private var agentColor: Color {
        switch msg.agent {
        case "calendar-agent": return .blue
        case "notes-agent":    return .orange
        case "tasks-agent":    return .green
        default:               return .secondary
        }
    }

    private var agentLabel: String {
        switch msg.agent {
        case "calendar-agent": return "Calendar"
        case "notes-agent":    return "Notes"
        case "tasks-agent":    return "Tasks"
        default:               return "Assistant"
        }
    }

    var body: some View {
        if msg.role == "user" {
            HStack {
                Spacer()
                Text(msg.content)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 340, alignment: .trailing)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let _ = msg.agent {
                    Label(agentLabel, systemImage: "person.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(agentColor)
                }
                Text(msg.content)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 380, alignment: .leading)
            }
        }
    }
}
