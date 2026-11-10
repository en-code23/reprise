import Foundation

struct DiscoveryResult: Sendable {
    var sessions: [ResumeSession] = []
    var warnings: [String] = []
}

/// Only metadata is retained. Conversation messages and tool output are never imported.
enum SessionDiscovery {
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiscoveryResult {
        var result = DiscoveryResult()
        let environment = ProcessInfo.processInfo.environment
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        let claude = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        var codexNames: [String: String] = [:]
        do { codexNames = try SessionNameMetadata.codexNames(at: codex.appendingPathComponent("session_index.jsonl")) }
        catch { result.warnings.append("Some Codex session names could not be read.") }
        for (root, model) in [(codex.appendingPathComponent("sessions"), AssistantModel.codex),
                              (claude.appendingPathComponent("projects"), AssistantModel.claude)] {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
            ) else {
                result.warnings.append("Could not read \(model.displayName) session folder.")
                continue
            }
            for case let file as URL in enumerator {
                if file.pathComponents.contains("subagents") { enumerator.skipDescendants(); continue }
                guard file.pathExtension == "jsonl" else { continue }
                do {
                    guard let handle = try? FileHandle(forReadingFrom: file) else {
                        result.warnings.append("Some \(model.displayName) sessions could not be read.")
                        continue
                    }
                    defer { try? handle.close() }
                    // Session headers are near the beginning; bound reads even for multi-GB transcripts.
                    var data = try handle.read(upToCount: 256 * 1024) ?? Data()
                    if model == .claude { data.append(try SessionNameMetadata.claudeTitleTail(from: handle)) }
                    let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .now
                    if var session = parse(data: data, model: model, modified: modified) {
                        if model == .codex { session.detectedName = codexNames[session.sessionIdentifier.lowercased()] }
                        result.sessions.append(session)
                    }
                } catch {
                    result.warnings.append("Some \(model.displayName) sessions could not be read.")
                }
            }
        }
        let grokHome = environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".grok")
        let grok = GrokSessionDiscovery.scan(root: grokHome.appendingPathComponent("sessions"))
        result.sessions.append(contentsOf: grok.sessions)
        result.warnings.append(contentsOf: grok.warnings)
        result.warnings = Array(Set(result.warnings)).sorted()
        return result
    }

    static func parse(data: Data, model: AssistantModel, modified: Date) -> ResumeSession? {
        var identifier: String?
        var directory: String?
        var detection = OriginDetection(origin: .unknown, evidence: [])
        var entrypoints = Set<String>()
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if model == .codex, object["type"] as? String == "session_meta",
               let payload = object["payload"] as? [String: Any] {
                identifier = payload["id"] as? String ?? payload["session_id"] as? String
                directory = payload["cwd"] as? String
                detection = SessionOriginDetector.codex(originator: payload["originator"] as? String, source: payload["source"] as? String)
                break
            }
            if model == .claude, object["isSidechain"] as? Bool != true {
                if let candidate = object["sessionId"] as? String {
                    if let identifier, identifier != candidate { continue }
                    identifier = candidate
                }
                directory = object["cwd"] as? String ?? directory
                if let entrypoint = object["entrypoint"] as? String { entrypoints.insert(entrypoint) }
                if object["type"] as? String == "custom-title", let id = object["sessionId"] as? String {
                    names[id.lowercased()] = SessionName.clean(object["customTitle"] as? String)
                }
            }
        }
        if model == .claude { detection = SessionOriginDetector.claude(entrypoints: entrypoints) }
        guard let identifier, UUID(uuidString: identifier) != nil,
              let directory, directory.hasPrefix("/") else { return nil }
        let command = CommandParser.resumeCommand(model: model, identifier: identifier)
        var session = ResumeSession(
            model: model, project: URL(fileURLWithPath: directory).lastPathComponent,
            projectDirectory: directory, note: "", command: command,
            createdAt: modified, detectedAutomatically: true
        )
        session.discoveryKey = "\(model.rawValue):\(command)"
        session.detectedOrigin = detection.origin
        session.sourceEvidence = detection.evidence
        session.detectedName = names[identifier.lowercased()]
        return session
    }
}
