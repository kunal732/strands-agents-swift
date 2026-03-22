import SwiftUI

struct RootView: View {
    @State private var model = AssistantModel()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            ChatView(model: model)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.messages.isEmpty || model.isThinking)
            }
        }
    }
}
