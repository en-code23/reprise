import XCTest
@testable import Reprise

final class GrokSessionDiscoveryTests: XCTestCase {
    private let id = "019a6523-8200-7000-8100-000000000001"

    private func summary(cwd: String = "/tmp/Project With Spaces", updated: String = "2026-11-08T08:30:00.123456Z") -> Data {
        Data("""
        {"info":{"id":"\(id)","cwd":"\(cwd)"},"updated_at":"\(updated)","generated_title":"Private generated title","session_summary":"Private conversation summary"}
        """.utf8)
    }

    func testReadsMetadataAndUsesActualResumeSyntax() throws {
        let session = try XCTUnwrap(GrokSessionDiscovery.parse(data: summary(), modified: .distantPast))
        XCTAssertEqual(session.model, .grok)
        XCTAssertEqual(session.projectDirectory, "/tmp/Project With Spaces")
        XCTAssertEqual(session.project, "Project With Spaces")
        XCTAssertEqual(session.command, "grok --resume \(id)")
        XCTAssertEqual(session.origin, .unknown)
        XCTAssertTrue(session.note.isEmpty)
        XCTAssertEqual(session.createdAt.timeIntervalSince1970, 1794126600.123456, accuracy: 0.001)
    }

    func testMalformedOrOversizeMetadataIsSkipped() {
        XCTAssertNil(GrokSessionDiscovery.parse(data: Data("{partial".utf8), modified: .now))
        XCTAssertNil(GrokSessionDiscovery.parse(data: Data("{\"info\":{\"id\":\"bad\",\"cwd\":\"/tmp\"}}".utf8), modified: .now))
        XCTAssertNil(GrokSessionDiscovery.parse(data: summary(cwd: "relative/path"), modified: .now))
        XCTAssertNil(GrokSessionDiscovery.parse(data: Data(repeating: 32, count: GrokSessionDiscovery.maximumSummarySize + 1), modified: .now))
    }

    func testMissingTimestampUsesFileModificationDate() throws {
        let fallback = Date(timeIntervalSince1970: 1234)
        let session = try XCTUnwrap(GrokSessionDiscovery.parse(data: summary(updated: "invalid"), modified: fallback))
        XCTAssertEqual(session.createdAt, fallback)
    }

    func testOnlySummaryFilesAreImportedAndDirectoryNamesAreNotDecoded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("encoded-wrong-directory").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try summary().write(to: folder.appendingPathComponent("summary.json"))
        try Data("not a transcript to import".utf8).write(to: folder.appendingPathComponent("chat_history.jsonl"))
        let child = folder.appendingPathComponent("subagents/child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try summary().write(to: child.appendingPathComponent("summary.json"))
        let result = GrokSessionDiscovery.scan(root: root)
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.projectDirectory, "/tmp/Project With Spaces")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    @MainActor func testRepeatedImportsPreserveNotesAndSourceOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let imported = try XCTUnwrap(GrokSessionDiscovery.parse(data: summary(), modified: .now))
        store.mergeDiscovered([imported])
        var edited = try XCTUnwrap(store.sessions.first)
        edited.note = "Continue here"
        edited.originOverride = .cli
        store.update(edited)
        store.mergeDiscovered([imported])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.note, "Continue here")
        XCTAssertEqual(store.sessions.first?.origin, .cli)
    }

    func testLegacyGrokCommandsAreCanonicalizedAndSafeToLaunch() throws {
        XCTAssertEqual(CommandParser.canonicalize("grok resume \"\(id)\""), "grok --resume \(id)")
        let session = ResumeSession(model: .grok, project: "Test", projectDirectory: NSTemporaryDirectory(), note: "", command: "grok resume \(id)", detectedAutomatically: true)
        XCTAssertTrue(try TerminalCommand.build(for: session).contains("'grok' '--resume' '\(id)'"))
    }
}
