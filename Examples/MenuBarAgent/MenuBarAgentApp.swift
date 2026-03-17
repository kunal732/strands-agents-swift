import SwiftUI

@main
struct MenuBarAgentApp: App {
    @State private var manager = AgentManager()

    var body: some Scene {
        MenuBarExtra {
            ChatView(manager: manager)
        } label: {
            Image(systemName: "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
