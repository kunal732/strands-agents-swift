// Writing Assistant -- Multi-Agent Graph Demo
//
// Three specialized agents analyze a draft in parallel (grammar, tone, clarity),
// then an editor agent synthesizes their feedback. Demonstrates GraphOrchestrator.

import SwiftUI
import StrandsAgents
import StrandsBedrockProvider

// MARK: - Agent State

enum AgentStatus { case waiting, running, done }

@Observable @MainActor
final class WritingAssistantModel {
    var draft = "The new feature is very good and it makes things work better. Users can now do stuff that they couldnt before which is great. We think this will be impactful for the business going forward and we look forward to seeing how it performs in the market."
    var grammarStatus: AgentStatus = .waiting
    var toneStatus:    AgentStatus = .waiting
    var clarityStatus: AgentStatus = .waiting
    var editorStatus:  AgentStatus = .waiting
    var synthesis = ""
    var isRunning = false
    var errorMessage: String?

    private let provider: BedrockProvider

    init() {
        provider = try! BedrockProvider(config: BedrockConfig(
            modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
            region: "us-east-1"
        ))
    }

    func analyze() async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        synthesis = ""
        grammarStatus = .waiting
        toneStatus    = .waiting
        clarityStatus = .waiting
        editorStatus  = .waiting

        let p = provider
        let text = draft

        let grammarAgent = Agent(model: p, systemPrompt: "You are a grammar expert. List grammar and spelling errors concisely.")
        let toneAgent    = Agent(model: p, systemPrompt: "You analyze writing tone. Identify tone issues and suggest improvements concisely.")
        let clarityAgent = Agent(model: p, systemPrompt: "You evaluate clarity. Flag vague language and suggest specific replacements concisely.")
        let editorAgent  = Agent(model: p, systemPrompt: "You are a senior editor. Synthesize the grammar, tone, and clarity feedback into the 3 most important improvements, numbered.")

        let graph = GraphOrchestrator(nodes: [
            GraphNode(id: "grammar",  agent: grammarAgent),
            GraphNode(id: "tone",     agent: toneAgent),
            GraphNode(id: "clarity",  agent: clarityAgent),
            GraphNode(id: "editor",   agent: editorAgent, dependencies: ["grammar", "tone", "clarity"]),
        ])

        // Animate statuses as nodes complete
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            grammarStatus = .running
            toneStatus    = .running
            clarityStatus = .running
        }

        do {
            let result = try await graph.run("Review this draft:\n\n\(text)")

            grammarStatus = .done
            toneStatus    = .done
            clarityStatus = .done
            editorStatus  = .running

            try? await Task.sleep(nanoseconds: 300_000_000)
            editorStatus = .done
            synthesis = result.finalResult?.message.textContent ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }

        isRunning = false
    }
}

// MARK: - App Entry

@main
struct WritingAssistantApp: App {
    var body: some Scene {
        WindowGroup("Writing Assistant") {
            ContentView()
                .frame(minWidth: 700, minHeight: 600)
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @State private var model = WritingAssistantModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Title
            VStack(alignment: .leading, spacing: 4) {
                Text("Writing Assistant")
                    .font(.largeTitle.bold())
                Text("Three agents analyze your draft in parallel, then an editor synthesizes their feedback.")
                    .foregroundStyle(.secondary)
            }

            // Draft input
            VStack(alignment: .leading, spacing: 6) {
                Text("Your draft").font(.headline)
                TextEditor(text: $model.draft)
                    .font(.body)
                    .frame(height: 100)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            }

            // Agent pipeline
            HStack(spacing: 12) {
                AgentBadge(label: "Grammar",  status: model.grammarStatus, color: .blue)
                AgentBadge(label: "Tone",     status: model.toneStatus,    color: .purple)
                AgentBadge(label: "Clarity",  status: model.clarityStatus, color: .orange)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                AgentBadge(label: "Editor",   status: model.editorStatus,  color: .green)
            }

            // Analyze button
            Button {
                Task { await model.analyze() }
            } label: {
                HStack {
                    if model.isRunning { ProgressView().controlSize(.small) }
                    Text(model.isRunning ? "Analyzing..." : "Analyze Draft")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)

            // Error
            if let err = model.errorMessage {
                Text("Error: \(err)").foregroundStyle(.red).font(.caption)
            }

            // Synthesis
            if !model.synthesis.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Editor's Synthesis", systemImage: "sparkles")
                        .font(.headline)
                    ScrollView {
                        Text(model.synthesis)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxHeight: 200)
                }
            }

            Spacer()
        }
        .padding(20)
    }
}

struct AgentBadge: View {
    let label: String
    let status: AgentStatus
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch status {
                case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.mini)
                case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(color)
                }
            }
            Text(label).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(status == .done ? color.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(status == .done ? color.opacity(0.4) : Color.secondary.opacity(0.3)))
        .animation(.easeInOut(duration: 0.3), value: status == .done)
    }
}
