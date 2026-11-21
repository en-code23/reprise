import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Reprise

final class AdditionalSessionDiscoveryTests: XCTestCase {
    private let id = "8d4b841b-1552-4b11-9a32-33b9205b836a"
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ value: Any) throws {
        try writeData(path, JSONSerialization.data(withJSONObject: value))
    }
    private func writeData(_ path: String, _ data: Data) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    private func sql(_ path: String, _ query: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, query, nil, nil, nil), SQLITE_OK)
    }

    func testNativeCommandsAndInjectionRejection() throws {
        for (client, input, expected) in [
            (AssistantModel.gemini, "gemini -r", "gemini --resume"),
            (.moonshot, "kimi --resume", "kimi --session"),
            (.antigravity, "agy --conversation", "agy --conversation"),
            (.opencode, "opencode -s", "opencode --session")
        ] {
            let parsed = CommandParser.parse("\(input) \"\(id)\"")
            XCTAssertEqual(parsed.model, client)
            XCTAssertEqual(parsed.command, "\(expected) \(id)")
            let session = ResumeSession(model: client, project: "Test", projectDirectory: root.path, note: "", command: parsed.command, detectedAutomatically: true)
            XCTAssertTrue(try TerminalCommand.build(for: session).contains(TerminalCommand.quote(id)))
            var injection = session; injection.command += "; touch /tmp/unsafe"
            XCTAssertThrowsError(try TerminalCommand.build(for: injection))
        }
        XCTAssertEqual(CommandParser.parse("GLM\nopencode --session ses_123456").model, .glm)
        XCTAssertEqual(CommandParser.parse("DeepSeek\nclaude --resume \(id)").command, "claude --resume \(id)")
        XCTAssertEqual(CommandParser.parse("DeepSeek session id: \(id)").command, "")
    }

    func testGeminiLegacyAndJsonlFindDirectoriesAndExcludeChildren() throws {
        try write(".gemini/projects.json", ["projects": ["/work/checkout": "checkout-123"]])
        try write(".gemini/tmp/checkout-123/chats/session-old.json", ["sessionId": id, "summary": "Payment retry", "lastUpdated": "2026-01-01T00:00:00Z", "messages": [["content": "DO NOT IMPORT PROMPT"]]])
        let hash = SHA256.hash(data: Data("/work/checkout".utf8)).map { String(format: "%02x", $0) }.joined()
        let head = try JSONSerialization.data(withJSONObject: ["sessionId": "session_abcdef", "projectHash": hash, "kind": "main"])
        let tail = try JSONSerialization.data(withJSONObject: ["$set": ["summary": "Newest title", "lastUpdated": "2026-11-21T12:00:00Z"]])
        try writeData(".gemini/tmp/\(hash)/chats/session-new.jsonl", head + Data("\n".utf8) + Data(repeating: 120, count: 700_000) + Data("\n".utf8) + tail)
        try write(".gemini/tmp/checkout-123/chats/session-child.json", ["sessionId": "child_123456", "kind": "subagent"])
        try writeData(".gemini/tmp/checkout-123/chats/session-corrupt.json", Data("broken".utf8))
        let sessions = try AdditionalSessionDiscovery.scanGemini(root: root.appendingPathComponent(".gemini"))
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.projectDirectory == "/work/checkout" && $0.note.isEmpty })
        XCTAssertEqual(sessions.first { $0.sessionIdentifier == "session_abcdef" }?.detectedName, "Newest title")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(sessions), as: UTF8.self).contains("DO NOT IMPORT PROMPT"))
    }

    func testGeminiMissingRegistryStillUsesMarkerOrAllowsFolderAssignment() throws {
        try writeData(".gemini/tmp/known/.project_root", Data("/work/known\n".utf8))
        for project in ["known", "unmapped"] {
            try write(".gemini/tmp/\(project)/chats/session-main.json", ["sessionId": project + "_123456"])
        }
        let sessions = try AdditionalSessionDiscovery.scanGemini(root: root.appendingPathComponent(".gemini"))
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first { $0.projectDirectory != nil }?.projectDirectory, "/work/known")
        XCTAssertEqual(ProjectLibrary.area(for: sessions.first { $0.projectDirectory == nil }?.projectDirectory), .unassigned)
    }

    func testBothKimiGenerationsAndLegacyContextsAreDiscovered() throws {
        let directory = "/work/kimi"
        let hash = Insecure.MD5.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
        try write(".kimi/kimi.json", ["work_dirs": [["path": directory, "kaos": "local"], ["path": "/remote", "kaos": "ssh"]]])
        try writeData(".kimi/sessions/\(hash)/\(id)/context.jsonl", Data("PRIVATE CONTEXT".utf8))
        try write(".kimi/sessions/\(hash)/\(id)/state.json", ["custom_title": "Kimi checkout"])
        try writeData(".kimi/sessions/\(hash)/legacy_123456.jsonl", Data("legacy".utf8))
        try write(".kimi-code/sessions/wd_hash/session_abcdef/state.json", ["id": "session_abcdef", "cwd": directory, "title": "New Kimi", "updatedAt": 1795262400000])
        try writeData(".kimi-code/sessions/wd_hash/session_abcdef/agents/main/wire.jsonl", Data("PRIVATE WIRE".utf8))
        try writeData(".kimi-code/sessions/wd_hash/session_abcdef/agents/child/wire.jsonl", Data("PRIVATE CHILD".utf8))
        let old = try AdditionalSessionDiscovery.scanKimi(root: root.appendingPathComponent(".kimi"))
        let new = try AdditionalSessionDiscovery.scanKimiCode(root: root.appendingPathComponent(".kimi-code"))
        XCTAssertEqual(old.count, 2); XCTAssertEqual(new.count, 1)
        XCTAssertEqual(old.first { $0.sessionIdentifier == id }?.detectedName, "Kimi checkout")
        XCTAssertEqual(new.first?.command, "kimi --session session_abcdef")
        XCTAssertTrue((old + new).allSatisfy { $0.model == .moonshot && $0.note.isEmpty })
    }

    func testOpenCodeBothDatabaseVersionsModelsAndStableIdentity() throws {
        try sql("opencode/opencode.db", """
        CREATE TABLE session(id TEXT,directory TEXT,title TEXT,time_updated INTEGER,parent_id TEXT);
        CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT);
        INSERT INTO session VALUES ('ses_deepseek','/work/app','Old title',1000000000000,NULL);
        INSERT INTO message VALUES ('msg_1','ses_deepseek',1,'{"role":"assistant","modelID":"deepseek-chat","providerID":"deepseek"}');
        INSERT INTO session VALUES ('ses_child','/work/app','Child',1000000000000,'ses_deepseek');
        CREATE TABLE session_v2(id TEXT,directory TEXT,title TEXT,time_updated INTEGER,parent_id TEXT,model TEXT);
        CREATE TABLE session_message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT);
        INSERT INTO session_v2 VALUES ('ses_deepseek','/work/app','Latest title',1795262400000,NULL,'{"id":"glm-5","providerID":"zai-coding-plan"}');
        INSERT INTO session_v2 VALUES ('ses_kimi123','/work/app','Kimi via OpenCode',1795262400000,NULL,'{"id":"moonshotai/kimi-k2","providerID":"openrouter"}');
        INSERT INTO session_v2 VALUES ('ses_generic','/work/app','Generic',1795262400000,NULL,'{"id":"gpt-6","providerID":"openai"}');
        INSERT INTO message VALUES ('msg_2','ses_generic',1,'{"role":"assistant","modelID":"deepseek-chat","providerID":"deepseek"}');
        INSERT INTO session_message VALUES ('msg_2','ses_generic',1,'{"role":"assistant","modelID":"deepseek-chat","providerID":"deepseek"}');
        """)
        let file = root.appendingPathComponent("opencode/opencode.db")
        let before = try Data(contentsOf: file)
        let sessions = try AdditionalSessionDiscovery.scanOpenCode(root: root.appendingPathComponent("opencode"))
        XCTAssertEqual(sessions.count, 3)
        let glm = try XCTUnwrap(sessions.first { $0.model == .glm })
        XCTAssertEqual(glm.command, "opencode --session ses_deepseek")
        XCTAssertEqual(glm.detectedName, "Latest title")
        XCTAssertTrue(glm.sourceLabel.contains("OpenCode"))
        var changed = glm; changed.model = .deepseek
        XCTAssertEqual(glm.identityKey, changed.identityKey)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(sessions.contains { $0.model == .moonshot })
        XCTAssertTrue(sessions.contains { $0.model == .opencode })
    }

    func testOpenCodeLegacyJsonAndUnreadableFileDoNotHideOtherSessions() throws {
        try write("opencode/storage/session/project/ses_legacy.json", ["id": "ses_legacy", "directory": "/work/app", "title": "Old session", "time": ["updated": 1795262400000]])
        try write("opencode/storage/message/ses_legacy/msg_latest.json", ["role": "assistant", "modelID": "deepseek-v4", "content": "PRIVATE MESSAGE"])
        try write("opencode/storage/session/project/ses_child.json", ["id": "ses_child", "parentID": "ses_legacy"])
        try writeData("opencode/storage/session/project/broken.json", Data("bad".utf8))
        let sessions = try AdditionalSessionDiscovery.scanOpenCode(root: root.appendingPathComponent("opencode"))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.model, .deepseek)
        XCTAssertEqual(sessions.first?.command, "opencode --session ses_legacy")
    }

    func testAntigravityIndexUsesLocalUrisAndExcludesChildren() throws {
        try sql("agy/conversation_summaries.db", """
        CREATE TABLE conversation_summaries(conversation_id TEXT,title TEXT,workspace_uris TEXT,last_modified_time TEXT,parent_conversation_id TEXT,nesting_depth INTEGER,source TEXT);
        INSERT INTO conversation_summaries VALUES ('\(id)','CLI work','["file:///work/Billing%20Portal"]','2026-11-21 12:30:00.123456+00:00','',0,'cli');
        INSERT INTO conversation_summaries VALUES ('child_123456','Child','[]','2026-11-21T12:00:00Z','\(id)',1,'cli');
        INSERT INTO conversation_summaries VALUES ('remote_123456','Remote','["vscode-remote://ssh-remote/server/app"]','2026-11-21T12:00:00Z','',0,'');
        """)
        let sessions = try AdditionalSessionDiscovery.scanAntigravity(root: root.appendingPathComponent("agy"))
        XCTAssertEqual(sessions.count, 2)
        let local = try XCTUnwrap(sessions.first { $0.sessionIdentifier == id })
        XCTAssertEqual(local.projectDirectory, "/work/Billing Portal")
        XCTAssertEqual(local.command, "agy --conversation \(id)")
        XCTAssertEqual(local.origin, .cli)
        XCTAssertEqual(local.createdAt.timeIntervalSince1970, 1795264200.123456, accuracy: 0.001)
        XCTAssertNil(sessions.first { $0.sessionIdentifier == "remote_123456" }?.projectDirectory)
    }

    @MainActor func testClaudeProviderMetadataReclassifiesWithoutDuplicatingOrRouting() async throws {
        let header = "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"\(root.path)\",\"entrypoint\":\"cli\"}\n"
        let reply = "{\"type\":\"assistant\",\"sessionId\":\"\(id)\",\"message\":{\"model\":\"glm-5\",\"content\":\"PRIVATE\"}}\n"
        var original = try XCTUnwrap(SessionDiscovery.parse(data: Data(header.utf8), model: .claude, modified: .now))
        original.note = "Keep note"; original.name = "Keep name"
        let store = SessionStore(directory: root.appendingPathComponent("store")); store.add(original)
        let imported = try XCTUnwrap(SessionDiscovery.parse(data: Data((header + reply).utf8), model: .claude, modified: .now))
        store.mergeDiscovered([imported])
        XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(store.sessions.first?.model, .glm)
        XCTAssertEqual(store.sessions.first?.name, "Keep name"); XCTAssertEqual(store.sessions.first?.note, "Keep note")
        var manual = try XCTUnwrap(store.sessions.first)
        manual.assistantOverride = .deepseek; manual.model = .deepseek; store.update(manual)
        store.mergeDiscovered([imported])
        XCTAssertEqual(store.sessions.first?.model, .deepseek)
        manual = try XCTUnwrap(store.sessions.first); manual.assistantOverride = nil; manual.model = manual.detectedAssistant ?? .other; store.update(manual)
        XCTAssertEqual(store.sessions.first?.model, .glm)
        XCTAssertEqual(imported.command, "claude --resume \(id)")
        let routing = RoutingStore(directory: root.appendingPathComponent("routing")); routing.preferences.enabled = true; routing.preferences.continuous = true
        XCTAssertFalse(routing.usesManagedSession(imported))
        let decision = await routing.decision(for: imported)
        XCTAssertNil(decision)
        let restored = try XCTUnwrap(SessionDiscovery.parse(data: Data((header + reply + reply.replacingOccurrences(of: "glm-5", with: "claude-sonnet")).utf8), model: .claude, modified: .now))
        XCTAssertEqual(restored.model, .claude)
    }

    func testModelMetadataTailDoesNotRetainContentAndLatestModelWins() throws {
        let header = "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/work/app\"}\n"
        let reply = "\n{\"type\":\"assistant\",\"sessionId\":\"\(id)\",\"message\":{\"model\":\"deepseek-chat\",\"content\":\"PRIVATE\"}}\n"
        try writeData("large.jsonl", Data(header.utf8) + Data(repeating: 120, count: 600_000) + Data(reply.utf8))
        let handle = try FileHandle(forReadingFrom: root.appendingPathComponent("large.jsonl")); defer { try? handle.close() }
        let tail = try SessionNameMetadata.claudeTitleTail(from: handle)
        XCTAssertFalse(String(decoding: tail, as: UTF8.self).contains("PRIVATE"))
        XCTAssertEqual(SessionDiscovery.parse(data: Data(header.utf8) + tail, model: .claude, modified: .now)?.model, .deepseek)
    }

    func testSymlinkAndOversizedLegacyMetadataAreSkipped() throws {
        try write("outside.json", ["sessionId": id])
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".gemini/tmp/test/chats"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".gemini/tmp/test/chats/session-link.json"), withDestinationURL: root.appendingPathComponent("outside.json"))
        try writeData(".gemini/tmp/test/chats/session-big.json", Data(repeating: 120, count: 16 * 1024 * 1024 + 1))
        XCTAssertTrue(try AdditionalSessionDiscovery.scanGemini(root: root.appendingPathComponent(".gemini")).isEmpty)
        XCTAssertNil(AdditionalSessionDiscovery.session(client: .opencode, id: "bad;rm", directory: "/work", title: nil, updated: nil))
    }

    func testAutomaticScanFindsNewToolsAndKeepsClientsDistinct() throws {
        try write(".gemini/tmp/project/chats/session-main.json", ["sessionId": id])
        try write(".local/share/opencode/storage/session/project/main.json", ["id": id, "directory": "/work/app"])
        let result = SessionDiscovery.scan(home: root, environment: [:])
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(Set(result.sessions.map(\.model)), [.gemini, .opencode])
        XCTAssertEqual(Set(result.sessions.map(\.identityKey)).count, 2)
    }
}
