import SwiftUI
import StrandsAgents

// MARK: - Data types

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String            // "user" or "assistant"
    let content: String
    let specialist: String?     // which agent handled this reply
}

struct SpecialistInfo: Identifiable {
    let id: String
    let label: String
    let icon: String
    let color: Color
    let description: String
}

let allSpecialists: [SpecialistInfo] = [
    SpecialistInfo(id: "coordinator",    label: "Coordinator", icon: "arrow.triangle.branch", color: .gray,   description: "Routes your request"),
    SpecialistInfo(id: "calendar-agent", label: "Calendar",    icon: "calendar",              color: .blue,   description: "Meetings & events"),
    SpecialistInfo(id: "notes-agent",    label: "Notes",       icon: "note.text",             color: .orange, description: "Documents & search"),
    SpecialistInfo(id: "tasks-agent",    label: "Tasks",       icon: "checkmark.circle",      color: .green,  description: "Reminders & to-dos"),
]

// MARK: - Tools

nonisolated func checkCalendar(date: String) -> String {
    "Calendar for \(date): 10am Team standup, 2pm Design review, 4pm 1:1 with manager"
}
nonisolated func searchNotes(query: String) -> String {
    "Found 3 notes matching '\(query)': Meeting notes from Monday, Project plan draft, Weekly goals"
}
nonisolated func createReminder(title: String, dueDate: String) -> String {
    "Reminder created: '\(title)' due \(dueDate)"
}

let checkCalendarTool   = Tool(checkCalendar,   "Check the calendar for a given date.", name: "check_calendar")
let searchNotesTool     = Tool(searchNotes,     "Search notes by keyword.", name: "search_notes")
let createReminderTool  = Tool(createReminder,  "Create a reminder with a title and due date.", name: "create_reminder")

// MARK: - View model

@Observable @MainActor
final class AssistantModel {
    var messages: [ChatMessage] = []
    var activeSpecialist: String?
    var isThinking = false

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
                    You are a personal assistant coordinator. Hand off immediately -- do not answer yourself:
                    - "calendar-agent": schedule, events, meetings, calendar, availability
                    - "notes-agent": notes, documents, search, find information
                    - "tasks-agent": reminders, tasks, to-do, deadlines
                    """)),
            SwarmMember(id: "calendar-agent",
                description: "Calendar and scheduling",
                agent: Agent(model: p, tools: [checkCalendarTool],
                    systemPrompt: "You manage the user's calendar. Use checkCalendar and answer concisely.")),
            SwarmMember(id: "notes-agent",
                description: "Notes and documents",
                agent: Agent(model: p, tools: [searchNotesTool],
                    systemPrompt: "You manage notes. Use searchNotes and answer concisely.")),
            SwarmMember(id: "tasks-agent",
                description: "Reminders and tasks",
                agent: Agent(model: p, tools: [createReminderTool],
                    systemPrompt: "You manage reminders. Use createReminder and confirm what was created.")),
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
            messages.append(ChatMessage(role: "assistant",
                content: "Error: \(error.localizedDescription)", specialist: nil))
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
