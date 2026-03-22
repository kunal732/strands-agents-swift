import SwiftUI

struct EditorPane: View {
    var model: WritingModel

    var body: some View {
        VSplitView {
            draftEditor
                .frame(minHeight: 200)
            synthesisPane
                .frame(minHeight: 180)
        }
    }

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Draft", systemImage: "doc.text").font(.headline)
                Spacer()
                Text("\(model.draft.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            TextEditor(text: Binding(get: { model.draft }, set: { model.draft = $0 }))
                .font(.body)
                .padding(16)
                .disabled(model.isAnalyzing)
        }
    }

    private var synthesisPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Editor's Synthesis", systemImage: "sparkles").font(.headline)
                Spacer()
                if model.isAnalyzing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Agents running...").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if let err = model.errorMessage {
                Text("Error: \(err)").foregroundStyle(.red).padding(20)
            } else if model.synthesis.isEmpty {
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
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
