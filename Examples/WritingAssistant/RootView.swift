import SwiftUI

struct RootView: View {
    @State private var model = WritingModel()
    @State private var selectedAgent: String?

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(model: model, selectedAgent: $selectedAgent)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            if let id = selectedAgent,
               let agent = model.agents.first(where: { $0.id == id }),
               !agent.output.isEmpty {
                AgentDetailView(agent: agent)
            } else {
                EditorPane(model: model)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selectedAgent = nil
                    Task { await model.analyze() }
                } label: {
                    Label("Analyze", systemImage: "play.fill")
                }
                .disabled(model.isAnalyzing || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
            ToolbarItem {
                Button {
                    selectedAgent = nil
                    model.reset()
                } label: {
                    Label("Clear", systemImage: "arrow.counterclockwise")
                }
                .disabled(model.isAnalyzing)
            }
        }
    }
}
