import SwiftUI

@main
struct PersonalAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 800, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
