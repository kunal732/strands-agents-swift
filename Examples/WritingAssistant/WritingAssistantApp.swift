// Writing Assistant
// Multi-agent graph demo: grammar, tone, and clarity agents analyze a
// draft in parallel, then an editor synthesizes their feedback.

import SwiftUI
import StrandsAgents
import StrandsBedrockProvider

// MARK: - Model

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
        AgentResult(id: "grammar", label: "Grammar",  icon: "textformat.abc",   color: .blue),
        AgentResult(id: "tone",    label: "Tone",      icon: "waveform",         color: .purple),
        AgentResult(id: "clarity", label: "Clarity",   icon: "eye",              color: .orange),
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
            GraphNode(id: "grammar", agent: Agent(model: p, systemPrompt: "Grammar expert. List grammar and spelling errors with corrections. Be specific and concise.")),
            GraphNode(id: "tone",    agent: Agent(model: p, systemPrompt: "Tone analyst. Identify tone issues (vague, informal, weak). Give specific rewrites. Be concise.")),
            GraphNode(id: "clarity", agent: Agent(model: p, systemPrompt: "Clarity editor. Flag ambiguous phrases. Suggest precise replacements. Be concise.")),
            GraphNode(id: "editor",  agent: Agent(model: p, systemPrompt: "Senior editor. Synthesize the grammar, tone, and clarity feedback into the 3 most important improvements, numbered and ordered by impact."),
                      dependencies: ["grammar", "tone", "clarity"]),
        ])

        // Set stage-1 agents to running
        setStatus("grammar", .running)
        setStatus("tone",    .running)
        setStatus("clarity", .running)

        do {
            let result = try await graph.run("Review this draft:\n\n\(text)")

            for id in ["grammar", "tone", "clarity"] {
                setStatus(id, .done)
                if let r = result.nodeResults[id] {
                    setOutput(id, r.message.textContent ?? "")
                }
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
        synthesis = ""
        errorMessage = nil
        for i in agents.indices { agents[i].status = .idle; agents[i].output = "" }
    }

    private func setStatus(_ id: String, _ s: AgentStatus) {
        if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].status = s }
    }
    private func setOutput(_ id: String, _ o: String) {
        if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].output = o }
    }
}

// MARK: - App

@main
struct WritingAssistantApp: App {
    var body: some Scene {
        WindowGroup("Writing Assistant") {
            RootView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1000, height: 680)
    }
}

// MARK: - Root layout

struct RootView: View {
    @State private var model = WritingModel()
    @State private var selectedAgent: String? = nil

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 260)
        } detail: {
            detailPane
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.analyze() }
                } label: {
                    Label("Analyze", systemImage: "play.fill")
                }
                .disabled(model.isAnalyzing || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
            ToolbarItem {
                Button {
                    model.reset()
                    selectedAgent = nil
                } label: {
                    Label("Clear", systemImage: "arrow.counterclockwise")
                }
                .disabled(model.isAnalyzing)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedAgent) {
            Section("Agent Pipeline") {
                ForEach(model.agents) { agent in
                    AgentRow(agent: agent)
                        .tag(agent.id)
                }
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Three agents analyze your draft in parallel. The editor synthesizes their findings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption2)
                        Text("Grammar + Tone + Clarity run simultaneously")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Writing Assistant")
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedAgent, let agent = model.agents.first(where: { $0.id == id }), !agent.output.isEmpty {
            AgentDetailView(agent: agent)
        } else {
            mainEditor
        }
    }

    private var mainEditor: some View {
        VSplitView {
            // Draft editor
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Draft", systemImage: "doc.text")
                        .font(.headline)
                    Spacer()
                    Text("\(model.draft.split(whereSeparator: \.isWhitespace).count) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                Divider()

                TextEditor(text: $model.draft)
                    .font(.body)
                    .padding(16)
                    .disabled(model.isAnalyzing)
            }
            .frame(minHeight: 200)

            // Results pane
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Editor's Synthesis", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    if model.isAnalyzing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Analyzing...").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider()

                if let err = model.errorMessage {
                    Text("Error: \(err)")
                        .foregroundStyle(.red)
                        .padding(20)
                } else if model.synthesis.isEmpty && !model.isAnalyzing {
                    ContentUnavailableView(
                        "No Analysis Yet",
                        systemImage: "sparkles",
                        description: Text("Click Analyze to run the agent pipeline.")
                    )
                } else {
                    ScrollView {
                        Text(model.synthesis)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                }
            }
            .frame(minHeight: 180)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

// MARK: - Sidebar row

struct AgentRow: View {
    let agent: AgentResult

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(agent.color.opacity(0.15))
                    .frame(width: 32, height: 32)
                switch agent.status {
                case .idle:    Image(systemName: agent.icon).font(.system(size: 13)).foregroundStyle(agent.color.opacity(0.5))
                case .running: ProgressView().controlSize(.small).tint(agent.color)
                case .done:    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(agent.color)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.label).font(.subheadline.weight(.medium))
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if agent.status == .done && !agent.output.isEmpty {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.3), value: agent.status)
    }

    private var statusLabel: String {
        switch agent.status {
        case .idle:    return agent.id == "editor" ? "Waits for others" : "Waiting"
        case .running: return "Analyzing..."
        case .done:    return agent.output.isEmpty ? "Done" : "Tap to view"
        }
    }
}

// MARK: - Agent detail

struct AgentDetailView: View {
    let agent: AgentResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(agent.color.opacity(0.15)).frame(width: 40, height: 40)
                    Image(systemName: agent.icon).font(.system(size: 16)).foregroundStyle(agent.color)
                }
                VStack(alignment: .leading) {
                    Text(agent.label).font(.title2.bold())
                    Text("Analysis complete").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                Text(agent.output)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
