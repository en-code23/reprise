import AppKit

enum TerminalLaunchError: LocalizedError {
    case missingDirectory, invalidDirectory, invalidCommand, automation(String)
    var errorDescription: String? {
        switch self {
        case .missingDirectory: "Choose a project directory before resuming."
        case .invalidDirectory: "The project folder no longer exists. Choose its new location."
        case .invalidCommand: "Use a resume command with a single session ID. Shell scripts cannot be launched from Reprise."
        case .automation(let message): "Terminal could not open: \(message). Allow Reprise to control Terminal in System Settings → Privacy & Security → Automation."
        }
    }
}

enum TerminalCommand {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func build(for session: ResumeSession) throws -> String {
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
        return "cd -- \(quote(path)) && \(parts.map(quote).joined(separator: " "))"
    }
}

@MainActor
enum TerminalLauncher {
    static func launch(_ session: ResumeSession) async throws {
        let command = try TerminalCommand.build(for: session)
        // Compile-time script, dynamic command supplied as argv rather than interpolated AppleScript.
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "on run argv\ntell application \"Terminal\"\nactivate\ndo script (item 1 of argv)\nend tell\nend run", command]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw TerminalLaunchError.automation(String(decoding: data, as: UTF8.self))
            }
        }.value
    }
}
