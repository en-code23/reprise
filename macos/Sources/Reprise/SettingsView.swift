import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SessionStore
    init(store: SessionStore) { self.store = store }
    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: RepriseSettingsView(store: store))
            let window = NSWindow(contentViewController: controller)
            window.title = "Reprise Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 520, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct RepriseSettingsView: View {
    @ObservedObject var store: SessionStore
    var body: some View {
        Form {
            Section("Sessions") {
                Toggle("Automatically discover local sessions", isOn: $store.autoDiscovery)
                LabeledContent("Library") { Text("Stored on this Mac").foregroundStyle(.secondary) }
                Button("Sync now") { Task { await store.sync() } }.disabled(store.isSyncing)
            }
            Section("Open projects") {
                LabeledContent("Default terminal") { TerminalPreferencePicker().labelsHidden() }
                LabeledContent("Default editor") { EditorPreferenceMenu() }
            }
            Section("Updates") {
                CheckForUpdatesButton()
                Text(store.syncMessage).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(12).frame(width: 520, height: 520)
    }
}
