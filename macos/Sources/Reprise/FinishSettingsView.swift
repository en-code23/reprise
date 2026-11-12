import SwiftUI
import AppKit
import ApplicationServices
import UserNotifications

struct FinishSettingsView: View {
    @ObservedObject var controller: FinishController
    var target: FinishTarget?
    var sessionName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var connecting: String?
    @State private var shortcuts: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("When finished").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Actions run once, after the watched assistants finish. Resuming while armed uses a Reprise-managed terminal. For sessions started elsewhere, connect their hooks below. New work or input requests stop the countdown.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Form {
                        Toggle("Enable completion detection", isOn: $controller.preferences.enabled)
                        Picker("Action", selection: $controller.preferences.action) {
                            ForEach(FinishAction.allCases) { Text($0.title).tag($0) }
                        }
                        if controller.preferences.action != .notify && controller.preferences.action != .none {
                            Picker("Countdown", selection: $controller.preferences.delaySeconds) {
                                ForEach([15, 30, 60, 120, 300, 600], id: \.self) { Text($0 < 60 ? "\($0) seconds" : $0 == 60 ? "1 minute" : "\($0 / 60) minutes").tag($0) }
                            }
                        }
                        if controller.preferences.action == .shortcut {
                            TextField("Shortcut name", text: $controller.preferences.shortcutName)
                            HStack {
                                Button("Choose a Shortcut…") { Task { await loadShortcuts() } }
                                if !shortcuts.isEmpty {
                                    Picker("Shortcut", selection: $controller.preferences.shortcutName) {
                                        Text("Choose…").tag("")
                                        ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                                    }.labelsHidden()
                                }
                            }
                            Text("Runs the selected Shortcut without passing your conversation or project files. A Shortcut can perform other actions you set up, such as playing a sound or changing Focus.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if controller.preferences.action == .lock {
                            Text("Lock screen uses macOS’s Control–Command–Q shortcut. Allow Reprise in Accessibility and allow System Events automation when macOS asks.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Set up screen lock permissions…") {
                                Task {
                                    _ = try? await MacFinishExecutor.capture(URL(fileURLWithPath: "/usr/bin/osascript"), args: ["-e", "tell application \"System Events\" to get name"], timeout: 60)
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                }
                            }
                        }
                        if controller.preferences.action == .notify {
                            Button("Allow macOS notifications…") { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } }
                        }
                    }.formStyle(.columns)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(target == nil ? "Watch assistants" : "Selected session").fontWeight(.medium)
                        if let target {
                            Label(sessionName ?? target.provider.capitalized, systemImage: "terminal")
                            Text("Only this conversation can trigger the action. Other connected assistants must also finish or stop asking for input before a countdown begins.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 20) {
                                ForEach(["codex", "claude", "grok"], id: \.self) { provider in
                                    Toggle(provider.capitalized, isOn: Binding(get: { controller.preferences.providers.contains(provider) }, set: { enabled in
                                        if enabled { controller.preferences.providers.insert(provider) } else { controller.preferences.providers.remove(provider) }
                                    }))
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(controller.summary).font(.headline)
                        Text(controller.status).font(.callout).foregroundStyle(.secondary)
                        HStack {
                            if controller.armed {
                                Button("Cancel action", role: .cancel) { controller.cancel() }.controlSize(.large)
                            } else {
                                Button("Arm next completion") { _ = controller.arm(target: target) }
                                    .controlSize(.large).buttonStyle(.borderedProminent).tint(.repriseGreen)
                                    .disabled(controller.executing || !controller.preferences.ready || (target == nil && controller.preferences.providers.isEmpty))
                            }
                            Spacer()
                        }
                        Text("Arming expires after it runs, when Reprise quits, or when your Mac sleeps. Changing these settings cancels an armed action. This is a completed reply, not a promise the entire project is finished.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    DisclosureGroup("Sessions started outside Reprise") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Resuming a session while an action is armed opens a Reprise-managed terminal, independently of model selection. For sessions started elsewhere, connect their lifecycle hooks below. Existing sessions may need restarting or reloading hooks. Reprise must remain open.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(["codex", "claude", "grok"], id: \.self) { provider in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(provider.capitalized).fontWeight(.medium)
                                        Spacer()
                                        if connecting == provider { ProgressView().controlSize(.small) }
                                        Button("Connect") { connect(provider) }.disabled(connecting != nil)
                                        Button("Disconnect") { connect(provider, remove: true) }.disabled(connecting != nil)
                                    }
                                    if let status = controller.connectionStatus[provider] { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                }
                            }
                            Text("Connections add only Reprise’s own hooks and keep backups. Existing hooks and Codex’s notification command are preserved. Review and trust new Codex hooks in /hooks. Claude and Grok may take about a minute to confirm idle after a reply; permissions and subagents are not completion signals.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                    if let error = controller.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(.trailing, 4)
            }
        }.padding(24).frame(width: 620, height: 640).background(Color(nsColor: .windowBackgroundColor))
    }

    private func connect(_ provider: String, remove: Bool = false) {
        connecting = provider
        Task { await controller.connect(provider, remove: remove); connecting = nil }
    }
    private func loadShortcuts() async {
        if let text = try? await MacFinishExecutor.capture(URL(fileURLWithPath: "/usr/bin/shortcuts"), args: ["list"]) {
            shortcuts = text.split(whereSeparator: \.isNewline).map(String.init).sorted()
        }
    }
}

struct FinishCountdownView: View {
    @ObservedObject var controller: FinishController
    var notification = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(notification ? (controller.error == nil ? "Session finished" : "Action couldn’t run") : controller.machine.arm?.preferences.action.title ?? "When finished", systemImage: controller.error != nil ? "exclamationmark.triangle" : notification ? "checkmark.circle" : "moon")
                .font(.headline)
            if notification { Text(controller.error ?? controller.status).font(.callout).foregroundStyle(.secondary) }
            else {
                Text("In \(controller.secondsRemaining) seconds").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("More work or an input request cancels this countdown.").font(.caption).foregroundStyle(.secondary)
            }
            Button(notification ? "Dismiss" : "Cancel action", role: .cancel) { controller.cancel() }
                .keyboardShortcut(.cancelAction).controlSize(.large)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
