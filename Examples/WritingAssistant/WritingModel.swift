import SwiftUI
import StrandsAgents
import StrandsBedrockProvider

enum AgentStatus: Equatable { case idle, running, done }

struct AgentResult: Identifiable {
    let id: String
    let label: String
    let icon: String
    let color: Color
    var status: AgentStatus = .idle
    var output: String = ""
}

@Observable @MainActor
final class WritingModel {
    var draft = """
    The new feature is very good and it makes things work better. \
    Users can now do stuff that they couldnt before which is great. \
    We think this will be impactful for the business going forward \
    and we look forward to seeing how it performs in the market.
    """

    var agents: [AgentResult] = [
        AgentResult(id: "grammar", label: "Grammar",  icon: "textformat.abc",      color: .blue),
        AgentResult(id: "tone",    label: "Tone",      icon: "waveform",            color: .purple),
        AgentResult(id: "clarity", label: "Clarity",   icon: "eye",                 color: .orange),
        AgentResult(id: "editor",  label: "Editor",    icon: "pencil.and.scribble", color: .green),
    ]

    var synthesis = ""
    var isAnalyzing = false
    var errorMessage: String?

    private let provider = try! BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
        region: "us-east-1"
    ))

    func analyze() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        errorMessage = nil
        synthesis = ""
        for i in agents.indices { agents[i].status = .idle; agents[i].output = "" }

        let p = provider
        let text = draft

        let graph = GraphOrchestrator(nodes: [
            GraphNode(id: "grammar", agent: Agent(model: p,
                systemPrompt: "Grammar expert. List grammar and spelling errors with corrections. Be concise.")),
            GraphNode(id: "tone", agent: Agent(model: p,
                systemPrompt: "Tone analyst. Identify tone issues and give specific rewrites. Be concise.")),
            GraphNode(id: "clarity", agent: Agent(model: p,
                systemPrompt: "Clarity editor. Flag vague language and suggest precise replacements. Be concise.")),
            GraphNode(id: "editor", agent: Agent(model: p,
                systemPrompt: "Senior editor. Synthesize the grammar, tone, and clarity feedback into the 3 most important improvements, numbered by impact."),
                dependencies: ["grammar", "tone", "clarity"]),
        ])

        setStatus("grammar", .running)
        setStatus("tone",    .running)
        setStatus("clarity", .running)

        do {
            let result = try await graph.run("Review this draft:\n\n\(text)")

            for id in ["grammar", "tone", "clarity"] {
                setStatus(id, .done)
                setOutput(id, result.nodeResults[id]?.message.textContent ?? "")
            }
            setStatus("editor", .running)
            try? await Task.sleep(nanoseconds: 300_000_000)
            setStatus("editor", .done)
            synthesis = result.finalResult?.message.textContent ?? ""
        } catch {
            errorMessage = error.localizedDescription
            for i in agents.indices where agents[i].status == .running {
                agents[i].status = .idle
            }
        }
        isAnalyzing = false
    }

    func reset() {
        synthesis = ""; errorMessage = nil
        for i in agents.indices { agents[i].status = .idle; agents[i].output = "" }
    }

    private func setStatus(_ id: String, _ s: AgentStatus) {
        if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].status = s }
    }
    private func setOutput(_ id: String, _ o: String) {
        if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].output = o }
    }
}
