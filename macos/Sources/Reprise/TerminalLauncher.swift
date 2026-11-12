import AppKit

enum TerminalLaunchError: LocalizedError {
    case missingDirectory, invalidDirectory, invalidCommand, missingHistory, usageUnavailable, managedRunnerUnavailable, automation(String), notInstalled(String), oldGhostty
    var errorDescription: String? {
        switch self {
        case .missingDirectory: "Choose a project directory before resuming."
        case .invalidDirectory: "The project folder no longer exists. Choose its new location."
        case .invalidCommand: "Use a resume command with a single session ID. Shell scripts cannot be launched from Reprise."
        case .missingHistory: "This conversation’s history is not on this Mac. Open it in Codex first, then sync Reprise."
        case .usageUnavailable: "Included usage is exhausted or no eligible model is available. Refresh usage after its reset, or turn off automatic selection to use your tool’s own settings."
        case .managedRunnerUnavailable: "The managed-session component is missing. Reinstall Reprise or turn off continuous model switching in Settings."
        case .automation(let message): "\(message) Check System Settings → Privacy & Security → Automation and allow Reprise to control your selected terminal. For Ghostty, AppleScript must also be enabled in its configuration."
        case .notInstalled(let name): "\(name) is not installed. Install it or choose another app under Default terminal."
        case .oldGhostty: "Ghostty 1.3 or newer is required to resume sessions. Update Ghostty or choose another default terminal."
        }
    }
}

enum TerminalCommand {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func build(for session: ResumeSession, decision: RoutingDecision? = nil) throws -> String {
        guard session.hasLocalHistory != false else { throw TerminalLaunchError.missingHistory }
        guard let directory = session.projectDirectory, !directory.isEmpty else { throw TerminalLaunchError.missingDirectory }
        let path = (directory as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw TerminalLaunchError.invalidDirectory }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalLaunchError.invalidDirectory
        }
        let command = CommandParser.canonicalize(session.command)
        let parts = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 3, ["codex", "claude", "grok"].contains(parts[0]),
              ["resume", "--resume"].contains(parts[1]),
              parts[2].range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
            throw TerminalLaunchError.invalidCommand
        }
        if decision?.blocked == true { throw TerminalLaunchError.usageUnavailable }
        let routed = parts + (decision?.arguments(provider: AssistantModel(rawValue: parts[0]) ?? .other) ?? [])
        return "cd -- \(quote(path)) && \(routed.map(quote).joined(separator: " "))"
    }
}

@MainActor
enum TerminalLauncher {
    static func launch(_ session: ResumeSession, terminal requestedTerminal: TerminalApp? = nil) async throws {
        let terminal = requestedTerminal ?? TerminalPreference.selected()
        // Validate the saved command/folder before contacting any provider.
        _ = try TerminalCommand.build(for: session)
        let routing = RoutingStore.shared
        let command: String
        if routing.usesManagedSession(session) || FinishController.shared.usesManagedSession(session) {
            let arguments = try ManagedSessionCommand.arguments(for: session, routing: routing)
            let path = (session.projectDirectory! as NSString).expandingTildeInPath
            command = "cd -- \(TerminalCommand.quote(path)) && " + arguments.map(TerminalCommand.quote).joined(separator: " ")
        } else {
            let decision = await routing.decision(for: session)
            command = try TerminalCommand.build(for: session, decision: decision)
        }
        guard let applicationURL = terminal.applicationURL else { throw TerminalLaunchError.notInstalled(terminal.name) }
        if terminal == .ghostty,
           let version = Bundle(url: applicationURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           version.compare("1.3.0", options: .numeric) == .orderedAscending {
            throw TerminalLaunchError.oldGhostty
        }
        let directory = (session.projectDirectory! as NSString).expandingTildeInPath
        // Compile-time script, dynamic command supplied as argv rather than interpolated AppleScript.
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", terminal.appleScript, command, directory]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw TerminalLaunchError.automation("\(terminal.name) could not open: " + String(decoding: data, as: UTF8.self))
            }
        }.value
    }
}
