import SwiftUI
import AppKit

@main
struct DesktopAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let manager = AssistantManager()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)

            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Desktop Assistant")
                button.action = #selector(togglePopover)
                button.target = self
            }

            popover = NSPopover()
            popover.contentSize = NSSize(width: 480, height: 520)
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: AssistantView(manager: manager))

            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 0 {
                    DispatchQueue.main.async { self?.showPopover() }
                }
            }

            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {
                    Task { @MainActor in self?.manager.cancelCurrentTask() }
                    return nil
                }
                return event
            }

            await manager.setup()
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
