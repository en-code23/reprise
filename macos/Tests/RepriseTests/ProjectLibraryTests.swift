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

    func testSearchMatchesOlderSessionNotesWithoutSplittingProject() {
        var older = session("/tmp/example", time: .distantPast)
        older.note = "Fix webhook retries"
        let groups = ProjectLibrary.groups([older, session("/tmp/example")], query: "webhook")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sessions.count, 2)
    }
}
