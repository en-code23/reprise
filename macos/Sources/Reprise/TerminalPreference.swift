import AppKit
import SwiftUI

enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case terminal, ghostty, iterm2
    var id: String { rawValue }
    var name: String {
        switch self { case .terminal: "Terminal"; case .ghostty: "Ghostty"; case .iterm2: "iTerm2" }
    }
    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .ghostty: "com.mitchellh.ghostty"
        case .iterm2: "com.googlecode.iterm2"
        }
    }

    @MainActor var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    // Each app receives commands as argv data, never interpolated script source.
    var appleScript: String {
        switch self {
        case .terminal:
            return """
            on run argv
                tell application id "com.apple.Terminal"
                    activate
                    do script (item 1 of argv)
                end tell
            end run
            """
        case .ghostty:
            return """
            on run argv
                tell application id "com.mitchellh.ghostty"
                    set cfg to new surface configuration
                    set initial working directory of cfg to (item 2 of argv)
                    set initial input of cfg to ((item 1 of argv) & linefeed)
                    new window with configuration cfg
                    activate
                end tell
            end run
            """
        case .iterm2:
            return """
            on run argv
                tell application id "com.googlecode.iterm2"
                    set win to (create window with default profile)
                    tell current session of win
                        write text (item 1 of argv)
                    end tell
                    activate
                end tell
            end run
            """
        }
    }
}

enum TerminalPreference {
    static let key = "preferredTerminal"
    static func selected(in defaults: UserDefaults = .standard) -> TerminalApp {
        TerminalApp(rawValue: defaults.string(forKey: key) ?? "") ?? .terminal
    }
}

struct TerminalPreferencePicker: View {
    @AppStorage(TerminalPreference.key) private var selected = TerminalApp.terminal.rawValue
    var body: some View {
        Picker("Default terminal", selection: $selected) {
            ForEach(TerminalApp.allCases) { terminal in
                Text(terminal.applicationURL == nil ? "\(terminal.name) (not installed)" : terminal.name)
                    .tag(terminal.rawValue)
            }
        }
        .pickerStyle(.menu)
    }
}
