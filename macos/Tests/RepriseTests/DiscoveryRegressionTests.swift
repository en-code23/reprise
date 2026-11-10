import XCTest
@testable import Reprise

final class DiscoveryRegressionTests: XCTestCase {
    private let id = "8d4b841b-1552-4b11-9a32-33b9205b836a"

    @MainActor func testDiscoveryRepairsFolderlessScreenshotWithoutReplacingItsIdentityOrEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(directory: folder)
        let captured = ResumeSession(model: .codex, project: "Bildschirmfoto 2026-08-30 um 22.55.36", name: "Keep my session name", note: "Keep my note", command: "codex resume \(id)", sourceFileName: "old.png", detectedAutomatically: false)
        store.add(captured)
        var discovered = ResumeSession(model: .codex, project: "resume", projectDirectory: "/Users/test/Documents/resume", note: "", command: captured.command, detectedAutomatically: true)
        discovered.discoveryKey = discovered.identityKey; discovered.detectedOrigin = .cli
        store.mergeDiscovered([discovered])
        let repaired = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(repaired.id, captured.id)
        XCTAssertEqual(repaired.projectDirectory, discovered.projectDirectory)
        XCTAssertEqual(repaired.project, "resume")
        XCTAssertEqual(repaired.name, captured.name)
        XCTAssertEqual(repaired.note, captured.note)
        XCTAssertEqual(repaired.command, captured.command)
        XCTAssertEqual(repaired.discoveryKey, discovered.discoveryKey)
        XCTAssertEqual(ProjectLibrary.groups(store.sessions, query: "resume").first?.area, .projects)
        XCTAssertEqual(SessionStore(directory: folder).sessions.first?.projectDirectory, discovered.projectDirectory)
    }

    @MainActor func testDiscoveryNeverOverwritesAChosenFolderOrProjectName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(directory: folder)
        var captured = ResumeSession(model: .codex, project: "My chosen label", note: "", command: "codex resume \(id)", detectedAutomatically: false)
        store.add(captured)
        var discovered = captured; discovered.project = "original"; discovered.projectDirectory = "/tmp/original"
        store.mergeDiscovered([discovered])
        XCTAssertEqual(store.sessions.first?.project, "My chosen label")
        captured = try XCTUnwrap(store.sessions.first); captured.projectDirectory = "/tmp/moved"
        store.update(captured); store.mergeDiscovered([discovered])
        XCTAssertEqual(store.sessions.first?.projectDirectory, "/tmp/moved")
    }

    func testCodexSubagentMetadataIsNotAUserSession() throws {
        let data = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/tmp/project\",\"originator\":\"codex-tui\",\"source\":{\"subagent\":{\"other\":\"guardian\"}}}}".utf8)
        XCTAssertNil(SessionDiscovery.parse(data: data, model: .codex, modified: .now))
        XCTAssertEqual(SessionDiscovery.parse(data: data, model: .codex, modified: .now, includeSubagents: true)?.isSubagent, true)
    }

    func testClaudeMetadataHeaderCannotTurnASidechainIntoAMainSession() throws {
        let data = Data("""
        {"type":"mode","sessionId":"\(id)","cwd":"/tmp/project"}
        {"type":"user","sessionId":"\(id)","cwd":"/tmp/project","isSidechain":true,"entrypoint":"sdk-py"}
        """.utf8)
        XCTAssertNil(SessionDiscovery.parse(data: data, model: .claude, modified: .now))
        XCTAssertEqual(SessionDiscovery.parse(data: data, model: .claude, modified: .now, includeSubagents: true)?.isSubagent, true)
    }

    @MainActor func testExistingSubagentEntriesAreHiddenWithoutDeletingTheirNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(directory: folder)
        var original = ResumeSession(model: .codex, project: "example", projectDirectory: "/tmp/example", note: "Keep this note", command: "codex resume \(id)", detectedAutomatically: true)
        store.add(original)
        original.isSubagent = true; store.mergeDiscovered([original])
        XCTAssertTrue(ProjectLibrary.groups(store.sessions, includeAutomation: true).isEmpty)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.note, "Keep this note")
        original.isSubagent = false; store.mergeDiscovered([original])
        XCTAssertEqual(ProjectLibrary.groups(store.sessions).count, 1)
    }
}
