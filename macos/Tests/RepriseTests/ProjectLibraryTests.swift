import XCTest
@testable import Reprise

final class ProjectLibraryTests: XCTestCase {
    private func session(_ directory: String?, model: AssistantModel = .claude, time: Date = .now) -> ResumeSession {
        ResumeSession(model: model, project: "Example", projectDirectory: directory, note: "", command: "\(model.commandName) resume \(UUID().uuidString)", createdAt: time, detectedAutomatically: true)
    }

    func testManySessionsBecomeOneProjectAcrossAssistants() throws {
        let sessions = (0..<20).map { index in session("/tmp/example/", model: index % 2 == 0 ? .codex : .claude, time: Date(timeIntervalSince1970: Double(index))) }
        let groups = ProjectLibrary.groups(sessions)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sessions.count, 20)
        XCTAssertEqual(groups.first?.assistants.count, 2)
        XCTAssertEqual(groups.first?.latest.createdAt, Date(timeIntervalSince1970: 19))
    }

    func testSameNameInDifferentFoldersStaysSeparate() {
        XCTAssertEqual(ProjectLibrary.groups([session("/tmp/client-a/app"), session("/tmp/client-b/app")]).count, 2)
    }

    func testHomeShorthandAndAbsolutePathShareOneProject() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let groups = ProjectLibrary.groups([session("~/Projects/example"), session(home + "/Projects/example/.")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sessions.count, 2)
    }

    func testUnassignedCapturesAndInternalFoldersAreNotProjects() {
        let groups = ProjectLibrary.groups([session(nil), session(nil), session("/Users/test/.codex/chat/workspace"), session("/tmp/project")])
        XCTAssertEqual(groups.filter { $0.area == .projects }.count, 1)
        XCTAssertEqual(groups.filter { $0.area == .unassigned }.count, 2)
        XCTAssertEqual(groups.filter { $0.area == .internalSessions }.count, 1)
    }

    func testSearchOnlyMatchesFolderBasenameAndKeepsCompleteHistory() {
        var older = session("/tmp/example", time: .distantPast)
        older.note = "Fix webhook retries"
        older.name = "checkout"
        older.project = "A custom project label"
        let records = [older, session("/tmp/example")]
        let groups = ProjectLibrary.groups(records, query: "  EXAMPLE ")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sessions.count, 2)
        for query in ["webhook", "checkout", "resume", "tmp", "custom", "claude"] {
            XCTAssertTrue(ProjectLibrary.groups(records, query: query).isEmpty, query)
        }
        XCTAssertTrue(ProjectLibrary.groups([session(nil)], query: "Example").isEmpty)
    }

    func testMainSessionsHideAutomationAndConfirmedSubagents() {
        var parent = session("/tmp/example"); parent.detectedOrigin = .cli
        var automation = session("/tmp/automation"); automation.detectedOrigin = .sdk
        var child = session("/tmp/child"); child.isSubagent = true; child.detectedOrigin = .cli
        let records = [parent, automation, child]
        XCTAssertEqual(ProjectLibrary.groups(records).map(\.latest.id), [parent.id])
        XCTAssertEqual(ProjectLibrary.groups(records, origin: .sdk).map(\.latest.id), [automation.id])
        XCTAssertEqual(ProjectLibrary.groups(records, includeAutomation: true).count, 2)
        XCTAssertFalse(ProjectLibrary.groups(records, includeAutomation: true).contains { $0.latest.id == child.id })
    }
}
