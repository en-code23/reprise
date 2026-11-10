import Foundation
import SQLite3

enum CodexHistoryIndex {
    static func scan(home: URL) -> DiscoveryResult {
        var result = DiscoveryResult()
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        let databases = files.compactMap { file -> (Int, URL)? in
            guard file.pathExtension == "sqlite", file.lastPathComponent.hasPrefix("state_"),
                  let version = Int(file.deletingPathExtension().lastPathComponent.dropFirst(6)) else { return nil }
            return (version, file)
        }.sorted { $0.0 > $1.0 }
        guard let file = databases.first?.1 else { return result }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            result.warnings = ["Codex history index could not be read."]
            return result
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        var columns = Set<String>()
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 1) { columns.insert(String(cString: text)) }
            }
        }
        sqlite3_finalize(statement); statement = nil
        guard columns.contains("id"), columns.contains("cwd") else { return result }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let updated = columns.contains("updated_at_ms") ? "COALESCE(updated_at_ms, \(column("updated_at")) * 1000)" : "\(column("updated_at")) * 1000"
        // Older app databases leave has_user_event at zero even for user conversations.
        let query = "SELECT id,cwd,\(column("rollout_path")),\(column("name")),\(column("title")),\(column("source")),\(column("originator")),\(updated) FROM threads ORDER BY 8 DESC LIMIT 5000"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            result.warnings = ["Codex history index format could not be read."]
            return result
        }
        defer { sqlite3_finalize(statement) }
        func text(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(statement) }
            guard let id = text(0), UUID(uuidString: id) != nil, let cwd = text(1), cwd.hasPrefix("/") else { continue }
            let source = text(5)
            let sourceObject = source.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let child = sourceObject?["subagent"] != nil || source?.hasPrefix("subagent") == true
            var session = ResumeSession(model: .codex, project: URL(fileURLWithPath: cwd).lastPathComponent,
                projectDirectory: cwd, note: "", command: CommandParser.resumeCommand(model: .codex, identifier: id),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7) / 1000), detectedAutomatically: true)
            session.discoveryKey = session.identityKey
            session.detectedName = SessionName.clean(text(3)) ?? SessionName.clean(text(4))
            let origin = SessionOriginDetector.codex(originator: text(6), source: sourceObject == nil ? source : nil)
            session.detectedOrigin = origin.origin; session.sourceEvidence = origin.evidence
            session.isSubagent = child
            session.hasLocalHistory = text(2).map { FileManager.default.fileExists(atPath: $0) } ?? false
            result.sessions.append(session)
        }
        if status != SQLITE_DONE { result.warnings.append("Some Codex history entries could not be read.") }
        return result
    }
}
