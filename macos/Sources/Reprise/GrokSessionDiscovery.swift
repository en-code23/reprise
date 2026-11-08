import Foundation

/// Grok Build keeps its index in summary.json; transcripts are not read.
enum GrokSessionDiscovery {
    static let maximumSummarySize = 1024 * 1024

    static func scan(root: URL) -> DiscoveryResult {
        var result = DiscoveryResult()
        guard FileManager.default.fileExists(atPath: root.path) else { return result }
        guard let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                result.warnings.append("Some Grok session folders could not be read.")
                return true
            }
        ) else {
            result.warnings.append("Could not read the Grok session folder.")
            return result
        }
        for case let file as URL in files {
            if file.lastPathComponent == "subagents" { files.skipDescendants(); continue }
            guard file.lastPathComponent == "summary.json" else { continue }
            do {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumSummarySize + 1) ?? Data()
                guard data.count <= maximumSummarySize else {
                    result.warnings.append("A Grok metadata file exceeded the 1 MB import limit.")
                    continue
                }
                if let session = parse(data: data, modified: attributes.contentModificationDate ?? .now) {
                    result.sessions.append(session)
                }
            } catch {
                result.warnings.append("Some Grok session metadata could not be read.")
            }
        }
        result.warnings = Array(Set(result.warnings)).sorted()
        return result
    }

    static func parse(data: Data, modified: Date) -> ResumeSession? {
        guard data.count <= maximumSummarySize,
              let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = summary["info"] as? [String: Any],
              let id = info["id"] as? String, UUID(uuidString: id) != nil,
              let directory = info["cwd"] as? String, directory.hasPrefix("/") else { return nil }
        let activity = [summary["last_active_at"], summary["updated_at"]]
            .compactMap { timestamp($0 as? String) }.max() ?? modified
        let command = CommandParser.resumeCommand(model: .grok, identifier: id)
        var session = ResumeSession(
            model: .grok, project: URL(fileURLWithPath: directory).lastPathComponent,
            projectDirectory: directory, note: "", command: command,
            createdAt: activity, detectedAutomatically: true
        )
        session.discoveryKey = "grok:\(command)"
        // TUI, headless, and ACP all share this format; it does not identify the client.
        session.detectedOrigin = .unknown
        session.sourceEvidence = ["format: Grok Build summary.json"]
        return session
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
