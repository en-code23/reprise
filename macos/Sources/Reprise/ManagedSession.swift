import Foundation

struct ManagedSessionRequest: Codable, Equatable {
    var provider: AssistantModel
    var sessionId: String
    var directory: String
    var configPath: String
    var projectKey: String
    var hostProbe: String?
}

@MainActor
enum ManagedSessionCommand {
    static var runnerURL: URL? {
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("reprise-agent"),
           FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let developer = root.appendingPathComponent("runner/target/debug/reprise-agent")
        if FileManager.default.isExecutableFile(atPath: developer.path) { return developer }
        #endif
        return nil
    }
    static func arguments(for session: ResumeSession, routing: RoutingStore, runner: URL? = nil) throws -> [String] {
        _ = try TerminalCommand.build(for: session)
        guard let runner = runner ?? runnerURL else { throw TerminalLaunchError.managedRunnerUnavailable }
        guard UUID(uuidString: session.sessionIdentifier) != nil, let directory = session.projectDirectory else { throw TerminalLaunchError.invalidCommand }
        let request = ManagedSessionRequest(provider: session.model, sessionId: session.sessionIdentifier,
            directory: (directory as NSString).expandingTildeInPath, configPath: routing.configurationURL.path,
            projectKey: ProjectLibrary.normalizedDirectory(directory) ?? directory, hostProbe: Bundle.main.executableURL?.path)
        let encoded = try JSONEncoder().encode(request).base64EncodedString()
        return [runner.path, "run", "--request", encoded]
    }
    static func clipboardCommand(for session: ResumeSession, routing: RoutingStore) throws -> String {
        guard routing.usesManagedSession(session) else { return session.command }
        return try arguments(for: session, routing: routing).map(TerminalCommand.quote).joined(separator: " ")
    }
}

@MainActor
enum RoutingCommandLine {
    /// Private metadata bridge for the bundled runner. This branch never starts AppKit,
    /// opens a model turn, or returns credentials to its caller.
    static func handle(_ args: [String]) -> Bool {
        guard args.dropFirst().first == "--routing-probe" else { return false }
        guard args.count >= 5, args[2] == "claude", args[3] == "--config", args[4].hasPrefix("/") else { exit(2) }
        let store = RoutingStore(directory: URL(fileURLWithPath: args[4]).deletingLastPathComponent())
        guard store.preferences.enabled, store.claudeConnected, store.storageError == nil else { exit(3) }
        var finished = false
        Task {
            do {
                let state = try await RoutingProviders.claude(fableKey: store.fableWindowID.isEmpty ? nil : store.fableWindowID)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
                try FileHandle.standardOutput.write(contentsOf: encoder.encode(state))
            } catch { exit(4) }
            finished = true
        }
        let deadline = Date().addingTimeInterval(25)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if !finished { exit(5) }
        return true
    }
}
