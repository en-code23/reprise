import CryptoKit
import Foundation
import SQLite3

/// Local indexes only. Never invokes an assistant, reads credentials, or modifies its history.
enum AdditionalSessionDiscovery {
    static func scan(home: URL, environment: [String: String]) -> DiscoveryResult {
        var result = DiscoveryResult()
        func root(_ key: String, _ fallback: URL) -> URL {
            environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? fallback
        }
        let geminiHome = root("GEMINI_CLI_HOME", home)
        let gemini = geminiHome.appendingPathComponent(".gemini")
        let sources: [(String, () throws -> [ResumeSession])] = [
            ("Gemini", { try scanGemini(root: gemini) }),
            ("Gemini", { try scanGemini(root: geminiHome.appendingPathComponent(".cache/.gemini")) }),
            ("Kimi", { try scanKimi(root: root("KIMI_SHARE_DIR", home.appendingPathComponent(".kimi"))) }),
            ("Kimi Code", { try scanKimiCode(root: root("KIMI_CODE_HOME", home.appendingPathComponent(".kimi-code"))) }),
            ("OpenCode", { try scanOpenCode(root: root("XDG_DATA_HOME", home.appendingPathComponent(".local/share")).appendingPathComponent("opencode")) }),
            ("Antigravity", { try scanAntigravity(root: home.appendingPathComponent(".gemini/antigravity-cli")) })
        ]
        for (name, scan) in sources {
            do { result.sessions += try scan() }
            catch { result.warnings.append("Some \(name) session metadata could not be read (unavailable, unsupported, or over the import limit).") }
        }
        return result
    }

    static func session(client: AssistantModel, id: String?, directory: String?, title: String?, updated: Any?,
                        modified: Date = .now, provider: AssistantModel? = nil, origin: SessionOrigin = .cli) -> ResumeSession? {
        guard let id, id.count <= 200, id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{5,}$"#, options: .regularExpression) != nil else { return nil }
        let directory = ProjectLibrary.normalizedDirectory(directory)
        let command = CommandParser.resumeCommand(model: client, identifier: id)
        var session = ResumeSession(model: provider ?? client,
            project: directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown project",
            projectDirectory: directory, note: "", command: command,
            createdAt: date(updated) ?? modified, detectedAutomatically: true)
        // Identity follows the client and ID, so a model switch doesn't duplicate a conversation.
        session.discoveryKey = "\(client.rawValue):\(command)"
        session.detectedName = SessionName.clean(title)
        session.detectedOrigin = origin
        session.sourceEvidence = ["client: \(client.displayName)"]
        session.isSubagent = false
        session.hasLocalHistory = true
        return session
    }

    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let seconds = n.doubleValue > 100_000_000_000 ? n.doubleValue / 1000 : n.doubleValue
            return seconds.isFinite && seconds > 0 && seconds < 253402300799 ? Date(timeIntervalSince1970: seconds) : nil
        }
        guard var text = value as? String else { return nil }
        if let number = Double(text) { return date(NSNumber(value: number)) }
        // Antigravity's SQLite timestamp is RFC3339 with a space and a numeric timezone.
        if text.count > 10, text[text.index(text.startIndex, offsetBy: 10)] == " " {
            text.replaceSubrange(text.index(text.startIndex, offsetBy: 10)...text.index(text.startIndex, offsetBy: 10), with: "T")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func scanGemini(root: URL) throws -> [ResumeSession] {
        var result: [ResumeSession] = []
        let registry = (try? object(root.appendingPathComponent("projects.json")))?["projects"] as? [String: String] ?? [:]
        var paths: [String: String] = [:]
        for (directory, slug) in registry {
            paths[slug] = directory
            paths[SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()] = directory
        }
        for project in try children(root.appendingPathComponent("tmp"), directories: true) {
            let marker = (try? read(project.appendingPathComponent(".project_root"), limit: 16 * 1024))
                .flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let directory = marker ?? paths[project.lastPathComponent]
            for file in try children(project.appendingPathComponent("chats"), directories: false)
                where file.lastPathComponent.hasPrefix("session-") && ["json", "jsonl"].contains(file.pathExtension) {
                var metadata: [String: Any] = [:]
                if file.pathExtension == "jsonl" {
                    // Read both ends; metadata updates can follow a multi-GB event stream.
                    for record in (try? records(file)) ?? [] {
                        if metadata.isEmpty, record["sessionId"] != nil { metadata = record }
                        if let update = record["$set"] as? [String: Any] {
                            for key in ["summary", "lastUpdated", "kind"] where update[key] != nil { metadata[key] = update[key] }
                        }
                    }
                } else { metadata = (try? object(file, limit: 16 * 1024 * 1024)) ?? [:] }
                guard metadata["kind"] as? String != "subagent" else { continue }
                if let session = session(client: .gemini, id: metadata["sessionId"] as? String,
                    directory: directory, title: metadata["summary"] as? String,
                    updated: metadata["lastUpdated"], modified: modified(file)) { result.append(session) }
            }
        }
        return result
    }

    static func scanKimi(root: URL) throws -> [ResumeSession] {
        var result: [ResumeSession] = []
        let workDirs = try object(root.appendingPathComponent("kimi.json"))?["work_dirs"] as? [[String: Any]] ?? []
        for workDir in workDirs {
            guard let path = workDir["path"] as? String, (workDir["kaos"] as? String ?? "local") == "local" else { continue }
            let hash = Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            let folder = root.appendingPathComponent("sessions/\(hash)")
            for entry in try children(folder, directories: true) {
                let context = entry.appendingPathComponent("context.jsonl")
                guard isFile(context), (try context.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else { continue }
                let state = (try? object(entry.appendingPathComponent("state.json"))) ?? (try? object(entry.appendingPathComponent("metadata.json"))) ?? [:]
                if let session = session(client: .moonshot, id: entry.lastPathComponent, directory: path,
                    title: state["custom_title"] as? String ?? state["title"] as? String, updated: nil, modified: modified(context)) { result.append(session) }
            }
            // Older Kimi versions stored contexts directly, without a per-session directory.
            for file in try children(folder, directories: false) where file.pathExtension == "jsonl" {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else { continue }
                if let session = session(client: .moonshot, id: file.deletingPathExtension().lastPathComponent,
                    directory: path, title: nil, updated: nil, modified: modified(file)) { result.append(session) }
            }
        }
        return result
    }

    static func scanKimiCode(root: URL) throws -> [ResumeSession] {
        var result: [ResumeSession] = []
        let index = try records(root.appendingPathComponent("session_index.jsonl"))
        let directories = Dictionary(index.compactMap { row -> (String, String)? in
            guard let id = row["sessionId"] as? String, let path = row["workDir"] as? String else { return nil }
            return (id, path)
        }, uniquingKeysWith: { _, last in last })
        for workDir in try children(root.appendingPathComponent("sessions"), directories: true) {
            for entry in try children(workDir, directories: true) {
                guard let state = try? object(entry.appendingPathComponent("state.json")),
                      let id = state["id"] as? String, id == entry.lastPathComponent,
                      isFile(entry.appendingPathComponent("agents/main/wire.jsonl")) else { continue }
                if let session = session(client: .moonshot, id: id,
                    directory: state["cwd"] as? String ?? directories[id],
                    title: state["title"] as? String, updated: state["updatedAt"], modified: modified(entry.appendingPathComponent("state.json"))) {
                    result.append(session)
                }
            }
        }
        return result
    }

    static func scanOpenCode(root: URL) throws -> [ResumeSession] {
        var result: [ResumeSession] = []
        if isFile(root.appendingPathComponent("opencode.db")) {
            let db = try MetadataDatabase(root.appendingPathComponent("opencode.db"))
            // v2 supersedes v1 for the same ID; both can coexist after migration.
            for (table, messages) in [("session", "message"), ("session_v2", "session_message")] {
                let columns = try db.columns(table)
                guard ["id", "directory", "title", "time_updated"].allSatisfy(columns.contains) else { continue }
                let model = columns.contains("model") ? "s.model" : "NULL"
                let parent = columns.contains("parent_id") ? "s.parent_id" : "NULL"
                let messageColumns = try db.columns(messages)
                let fallback = ["session_id", "data", "time_created"].allSatisfy(messageColumns.contains)
                    ? "(SELECT json_object('providerID',json_extract(data,'$.providerID'),'modelID',json_extract(data,'$.modelID')) FROM \(messages) m WHERE m.session_id=s.id AND json_valid(data) AND json_extract(data,'$.role')='assistant' ORDER BY time_created DESC LIMIT 1)" : "NULL"
                for row in try db.rows("SELECT s.id,s.directory,s.title,s.time_updated,\(model),\(fallback),\(parent) FROM \(table) s ORDER BY s.time_updated DESC LIMIT 5000") {
                    guard row[6]?.isEmpty != false else { continue }
                    let provider = row[4].map { $0.isEmpty || $0 == "null" } != false
                        ? recordedOpenCodeModel(row[5]) : recordedOpenCodeModel(row[4])
                    if let session = session(client: .opencode, id: row[0], directory: row[1], title: row[2], updated: row[3], provider: provider, origin: .unknown) { result.append(session) }
                }
            }
        }
        // Pre-SQLite OpenCode kept metadata in storage/session/<project>/<id>.json.
        for project in try children(root.appendingPathComponent("storage/session"), directories: true) {
            for file in try children(project, directories: false) where file.pathExtension == "json" {
                guard let info = try? object(file), (info["parentID"] as? String ?? "").isEmpty,
                      let id = info["id"] as? String, id.count <= 200,
                      id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{5,}$"#, options: .regularExpression) != nil else { continue }
                var provider: AssistantModel?
                let files = try children(root.appendingPathComponent("storage/message/\(id)"), directories: false)
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                for message in files.prefix(20) {
                    guard let value = try? object(message), value["role"] as? String == "assistant" else { continue }
                    provider = AssistantModel.recordedProvider(value["modelID"] as? String) ?? AssistantModel.recordedProvider(value["providerID"] as? String)
                    break
                }
                if let session = session(client: .opencode, id: id, directory: info["directory"] as? String,
                    title: info["title"] as? String, updated: (info["time"] as? [String: Any])?["updated"], modified: modified(file), provider: provider, origin: .unknown) { result.append(session) }
            }
        }
        // Prefer the newer v2 row; never let an old file overwrite its model or title.
        return Dictionary(result.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, last in last.createdAt >= first.createdAt ? last : first }).values.map { $0 }
    }

    private static func recordedOpenCodeModel(_ value: String?) -> AssistantModel? {
        guard let value else { return nil }
        if let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return AssistantModel.recordedProvider(object["modelID"] as? String ?? object["id"] as? String) ?? AssistantModel.recordedProvider(object["providerID"] as? String)
        }
        return AssistantModel.recordedProvider(value)
    }

    static func scanAntigravity(root: URL) throws -> [ResumeSession] {
        let file = root.appendingPathComponent("conversation_summaries.db")
        guard isFile(file) else { return [] }
        let db = try MetadataDatabase(file)
        let columns = try db.columns("conversation_summaries")
        guard ["conversation_id", "title", "workspace_uris", "last_modified_time"].allSatisfy(columns.contains) else { throw MetadataReadError.unsupported }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        return try db.rows("SELECT conversation_id,title,workspace_uris,last_modified_time,\(column("parent_conversation_id")),\(column("nesting_depth")),\(column("source")) FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 5000").compactMap { row in
            guard row[4]?.isEmpty != false, (Int(row[5] ?? "0") ?? 0) == 0 else { return nil }
            let uris = row[2]?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
            let directory = uris.compactMap { URL(string: $0) }.first { $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") }?.path
            let source = row[6]?.lowercased() ?? ""
            let origin: SessionOrigin = ["cli", "antigravity-cli"].contains(source) ? .cli : ["ide", "antigravity-ide"].contains(source) ? .ide : .unknown
            return session(client: .antigravity, id: row[0], directory: directory, title: row[1], updated: row[3], origin: origin)
        }
    }

    enum MetadataReadError: Error { case unreadable, oversized, unsupported }
    static func isFile(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    static func children(_ folder: URL, directories: Bool) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        guard (try folder.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).filter { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            return values.isSymbolicLink != true && (directories ? values.isDirectory == true : values.isRegularFile == true)
        }
    }
    static func read(_ file: URL, limit: Int = 1024 * 1024) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard isFile(file) else { return nil }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw MetadataReadError.oversized }
        return data
    }
    static func object(_ file: URL, limit: Int = 1024 * 1024) throws -> [String: Any]? {
        guard let data = try read(file, limit: limit) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    static func records(_ file: URL) throws -> [[String: Any]] {
        guard isFile(file) else { return [] }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let bound = 256 * 1024
        var data = try handle.read(upToCount: bound) ?? Data()
        let size = try handle.seekToEnd()
        if size > bound {
            try handle.seek(toOffset: max(UInt64(bound), size - UInt64(bound)))
            let tail = try handle.read(upToCount: bound) ?? Data()
            data.append(0x0A); data.append(tail.drop { $0 != 0x0A })
        }
        return data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
    static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
    }
}

private final class MetadataDatabase {
    private var db: OpaquePointer?
    init(_ file: URL) throws {
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw AdditionalSessionDiscovery.MetadataReadError.unreadable
        }
        sqlite3_busy_timeout(db, 500)
    }
    deinit { sqlite3_close(db) }
    func columns(_ table: String) throws -> Set<String> { Set(try rows("PRAGMA table_info(\(table))").compactMap { $0[1] }) }
    func rows(_ query: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw AdditionalSessionDiscovery.MetadataReadError.unsupported }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { index in
                guard sqlite3_column_bytes(statement, index) <= 16 * 1024 else { return nil }
                return sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw AdditionalSessionDiscovery.MetadataReadError.unreadable }
        return result
    }
}
