import XCTest
@testable import Reprise

final class SessionNameTests: XCTestCase {
    private let identifier = "8d4b841b-1552-4b11-9a32-33b9205b836a"
    private func session() -> ResumeSession {
        ResumeSession(model: .codex, project: "Billing", projectDirectory: "/tmp/billing", note: "", command: "codex resume \(identifier)", detectedAutomatically: true)
    }

    func testOldLibrariesDecodeAndNamesDoNotChangeCommands() throws {
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(session())) as? [String: Any])
        object.removeValue(forKey: "name"); object.removeValue(forKey: "detectedName")
        var legacy = try JSONDecoder().decode(ResumeSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.displayName, "Session · 205b836a")
        legacy.name = "Checkout retries"
        XCTAssertEqual(legacy.displayName, "Checkout retries")
        XCTAssertEqual(legacy.command, "codex resume \(identifier)")
        XCTAssertEqual(legacy.identityKey, session().identityKey)
        XCTAssertNil(SessionName.clean(" \n\t"))
        XCTAssertEqual(SessionName.clean("  Fix\n checkout\t👩‍💻  "), "Fix checkout 👩‍💻")
        XCTAssertEqual(SessionName.clean(String(repeating: "x", count: 500))?.count, 200)
    }

    @MainActor func testNamesSurviveSyncRestartAndDuplicateCapture() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(directory: folder)
        var imported = session(); imported.discoveryKey = imported.identityKey; imported.detectedName = "Original imported name"
        store.mergeDiscovered([imported])
        var edited = try XCTUnwrap(store.sessions.first); edited.name = " My checkout work "; edited.note = "Keep this note"
        store.update(edited)
        imported.detectedName = "Renamed upstream"
        store.mergeDiscovered([imported])
        XCTAssertEqual(store.sessions.first?.displayName, "My checkout work")
        XCTAssertEqual(store.sessions.first?.detectedName, "Renamed upstream")
        XCTAssertEqual(SessionStore(directory: folder).sessions.first?.displayName, "My checkout work")
        store.add(session())
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.displayName, "My checkout work")
        edited = try XCTUnwrap(store.sessions.first); edited.name = " "
        store.update(edited)
        XCTAssertEqual(store.sessions.first?.displayName, "Renamed upstream")
        XCTAssertEqual(ProjectLibrary.groups(store.sessions, query: "Renamed upstream").count, 1)
        XCTAssertEqual(ProjectLibrary.groups(store.sessions).first?.title, "Billing")
    }

    func testCodexAppendOnlyIndexUsesLastValidName() throws {
        let data = Data("""
        {"id":"\(identifier)","thread_name":"Original"}
        malformed
        {"id":"not-a-session","thread_name":"Ignore"}
        {"id":"\(identifier)","thread_name":"Newest name"}
        {"id":"\(identifier)","thread_name":
        """.utf8)
        XCTAssertEqual(SessionNameMetadata.codexNames(in: data), [identifier: "Newest name"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var large = Data(repeating: 120, count: SessionNameMetadata.maximumIndexBytes + 100)
        large.append(0x0A); large.append(data)
        try large.write(to: file)
        XCTAssertEqual(try SessionNameMetadata.codexNames(at: file)[identifier], "Newest name")
    }

    func testClaudeNamesMatchTheSessionAndCanBeReadFromBoundedTail() throws {
        let header = "{\"sessionId\":\"\(identifier)\",\"cwd\":\"/tmp/billing\",\"entrypoint\":\"cli\"}\n"
        let title = "{\"type\":\"custom-title\",\"sessionId\":\"\(identifier)\",\"customTitle\":\"Checkout work\"}\n"
        let other = "{\"type\":\"custom-title\",\"sessionId\":\"\(UUID().uuidString)\",\"customTitle\":\"Wrong session\"}\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((header + String(repeating: "x", count: 400_000) + "\n" + title + other + "{\"message\":\"Never import conversation content\"}\n").utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let tail = try SessionNameMetadata.claudeTitleTail(from: handle)
        XCTAssertFalse(String(decoding: tail, as: UTF8.self).contains("Never import"))
        let parsed = try XCTUnwrap(SessionDiscovery.parse(data: Data(header.utf8) + tail, model: .claude, modified: .now))
        XCTAssertEqual(parsed.detectedName, "Checkout work")
        XCTAssertTrue(parsed.note.isEmpty)
    }

    func testGrokImportsTitleWithoutConversationSummary() throws {
        let data = Data("{\"info\":{\"id\":\"\(identifier)\",\"cwd\":\"/tmp/billing\"},\"generated_title\":\"Webhook retries\",\"session_summary\":\"Private summary\"}".utf8)
        let parsed = try XCTUnwrap(GrokSessionDiscovery.parse(data: data, modified: .now))
        XCTAssertEqual(parsed.displayName, "Webhook retries")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self).contains("Private summary"))
    }
}
