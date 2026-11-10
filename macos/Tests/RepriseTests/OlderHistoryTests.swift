import XCTest
import SQLite3
@testable import Reprise

final class OlderHistoryTests: XCTestCase {
    private let id = "8d4b841b-1552-4b11-9a32-33b9205b836a"

    func testLegacyCodexIndexImportsZeroUserEventAndTracksAvailabilityWithoutWriting() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("state_5.sqlite")
        let rollout = home.appendingPathComponent("old.jsonl")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads(id TEXT,cwd TEXT,rollout_path TEXT,title TEXT,source TEXT,originator TEXT,updated_at INTEGER,has_user_event INTEGER);
        INSERT INTO threads VALUES('\(id)','/tmp/old-project','\(rollout.path)','Older conversation','cli','codex-tui',1700000000,0);
        INSERT INTO threads VALUES('00000000-0000-0000-0000-000000000001','/tmp/old-project','missing','Child','{"subagent":{"other":"guardian"}}',NULL,1700000001,0);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let before = try Data(contentsOf: file)
        let result = CodexHistoryIndex.scan(home: home)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.sessions.count, 2)
        let session = try XCTUnwrap(result.sessions.first { $0.sessionIdentifier == id })
        XCTAssertEqual(session.detectedName, "Older conversation")
        XCTAssertEqual(session.detectedOrigin, .cli)
        XCTAssertEqual(session.hasLocalHistory, false)
        XCTAssertEqual(session.createdAt, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(ProjectLibrary.groups(result.sessions).first?.sessions.count, 1)
        XCTAssertThrowsError(try TerminalCommand.build(for: session))
        XCTAssertEqual(try Data(contentsOf: file), before)
        try Data().write(to: rollout)
        XCTAssertEqual(CodexHistoryIndex.scan(home: home).sessions.first { $0.sessionIdentifier == id }?.hasLocalHistory, true)
    }

    func testOlderClaudeFindsDirectoryAfterLargeQueueWithoutRetainingMessages() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let queue = "{\"type\":\"queue-operation\",\"sessionId\":\"\(id)\",\"content\":\"" + String(repeating: "x", count: 520_000) + "\"}\n"
        let records = """
        {"type":"user","sessionId":"\(id)","cwd":"/tmp/older-project","entrypoint":"cli","message":{"content":"Never retain private text"}}
        {"type":"custom-title","sessionId":"\(id)","customTitle":"My title"}
        {"type":"ai-title","sessionId":"\(id)","aiTitle":"Automatic title"}
        """
        try Data((queue + records).utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var header = try handle.read(upToCount: 256 * 1024) ?? Data()
        let tail = try SessionNameMetadata.claudeTitleTail(from: handle)
        XCTAssertLessThan(tail.count, 2048)
        XCTAssertFalse(String(decoding: tail, as: UTF8.self).contains("Never retain private text"))
        header.append(tail)
        let session = try XCTUnwrap(SessionDiscovery.parse(data: header, model: .claude, modified: .now))
        XCTAssertEqual(session.projectDirectory, "/tmp/older-project")
        XCTAssertEqual(session.detectedName, "My title")
        XCTAssertEqual(session.detectedOrigin, .cli)
    }

    @MainActor func testAvailabilityRefreshPreservesUserEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(directory: folder)
        var session = ResumeSession(model: .codex, project: "old", name: "My name", projectDirectory: "/tmp/old", note: "My note", command: "codex resume \(id)", detectedAutomatically: true)
        session.hasLocalHistory = false; store.add(session)
        var incoming = session; incoming.hasLocalHistory = true; incoming.name = nil; incoming.note = ""
        store.mergeDiscovered([incoming])
        XCTAssertEqual(store.sessions.first?.hasLocalHistory, true)
        XCTAssertEqual(store.sessions.first?.name, "My name")
        XCTAssertEqual(store.sessions.first?.note, "My note")
    }

    func testArchivedTranscriptIsDiscoveredWithoutAnIndex() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = home.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/tmp/archive\",\"source\":\"cli\"}}\n".utf8)
            .write(to: archive.appendingPathComponent("old.jsonl"))
        let result = SessionDiscovery.scan(home: home, environment: [:])
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.sessionIdentifier, id)
        XCTAssertEqual(result.sessions.first?.hasLocalHistory, true)
    }
}
