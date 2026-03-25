// 07 - Multi-Agent Swarm
// A coordinator agent routes user requests to on-device specialists.
// Each specialist has its own tools and system prompt.
// Demonstrates dynamic handoff-based routing.

import Foundation
import StrandsAgents
import StrandsAgentsToolMacros

let provider = try BedrockProvider(config: BedrockConfig(
    modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
    region: "us-east-1"
))

// Tools for each specialist
@Tool
func searchNotes(query: String) -> String {
    "Found 3 notes matching '\(query)': 1) Meeting notes from Monday, 2) Project plan draft, 3) Weekly goals"
}

@Tool
func createReminder(title: String, dueDate: String) -> String {
    "Created reminder: '\(title)' due \(dueDate)"
}

@Tool
func checkCalendar(date: String) -> String {
    "Calendar for \(date): 10am Team standup, 2pm Design review, 4pm 1:1 with manager"
}

// Agents
let coordinator = Agent(
    model: provider,
    systemPrompt: """
    You are a personal assistant coordinator. Read the user's request and hand off to the right specialist:
    - Scheduling, events, availability: hand off to "calendar"
    - Notes, documents, searching for information: hand off to "notes"
    - Reminders, tasks, to-do items: hand off to "tasks"
    Hand off immediately. Do not try to answer yourself.
    """
)

let calendarAgent = Agent(
    model: provider,
    tools: [checkCalendar],
    systemPrompt: "You manage the user's calendar. Check availability, describe the schedule, and answer scheduling questions. Be concise."
)

let notesAgent = Agent(
    model: provider,
    tools: [searchNotes],
    systemPrompt: "You search and manage the user's notes. Find relevant notes and summarize them. Be concise."
)

let tasksAgent = Agent(
    model: provider,
    tools: [createReminder],
    systemPrompt: "You manage reminders and tasks. Create reminders, list tasks, and help the user stay organized. Be concise."
)

let swarm = SwarmOrchestrator(
    members: [
        SwarmMember(id: "coordinator", description: "Routes requests to the right specialist", agent: coordinator),
        SwarmMember(id: "calendar",    description: "Manages calendar and scheduling",         agent: calendarAgent),
        SwarmMember(id: "notes",       description: "Searches and manages notes",              agent: notesAgent),
        SwarmMember(id: "tasks",       description: "Creates reminders and manages tasks",     agent: tasksAgent),
    ],
    entryPoint: "coordinator"
)

let prompts = [
    "What's on my calendar today?",
    "Find my notes about the project plan",
    "Remind me to submit the report by Friday",
]

for prompt in prompts {
    print("User: \(prompt)")
    let result = try await swarm.run(prompt)
    print("Agent: \(result.finalResult?.message.textContent ?? "")\n")
}
