import XCTest
@testable import Reprise

final class FinishActionTests: XCTestCase {
    private let now = 1_800_000_000.0
    private let session = "8d4b841b-1552-4b11-9a32-33b9205b836a"
    private var preferences: FinishPreferences { var value = FinishPreferences(); value.enabled = true; value.action = .sleep; return value }
    private func event(_ kind: FinishEvent.Kind, provider: String = "codex", session: String? = nil, turn: String? = "turn-1", offset: Double = 1, source: String = "managed", child: String? = nil, background: Bool = false) -> FinishEvent {
        FinishEvent(id: UUID().uuidString, provider: provider, sessionId: session ?? self.session, turnId: turn, kind: kind,
            source: source, occurredAt: now + offset, childId: child, backgroundWork: background)
    }
    private func armed() -> FinishStateMachine {
        var machine = FinishStateMachine(); XCTAssertTrue(machine.enable(preferences, target: nil, now: now)); return machine
    }
    func testOffAndUnarmedNeverPerformAnAction() {
        var machine = FinishStateMachine()
        XCTAssertFalse(machine.enable(FinishPreferences(), target: nil, now: now))
        machine.receive(event(.completed), now: now + 1, uptime: 100)
        XCTAssertNil(machine.takeDue(uptime: 1000)); XCTAssertNil(machine.pending)
    }
    func testSuccessHasCountdownAndRunsOnlyOnce() {
        var machine = armed()
        machine.receive(event(.started), now: now + 1, uptime: 100)
        machine.receive(event(.completed, offset: 2), now: now + 2, uptime: 101)
        XCTAssertEqual(machine.pending?.deadline, 161)
        XCTAssertNil(machine.takeDue(uptime: 160))
        XCTAssertEqual(machine.takeDue(uptime: 161)?.action, .sleep)
        XCTAssertNil(machine.arm); XCTAssertNil(machine.takeDue(uptime: 162))
    }
    func testCancelDisarmsAndCannotExecuteLater() {
        var machine = armed(); machine.receive(event(.completed), now: now + 1, uptime: 100)
        machine.cancel(); XCTAssertNil(machine.takeDue(uptime: 160)); XCTAssertNil(machine.arm)
    }
    func testWaitingForPermissionAndNewWorkCancelCountdown() {
        for kind in [FinishEvent.Kind.waiting, .active, .started] {
            var machine = armed(); machine.receive(event(.completed), now: now + 1, uptime: 100)
            machine.receive(event(kind, turn: kind == .started ? "turn-2" : "turn-1", offset: 2), now: now + 2, uptime: 110)
            XCTAssertNil(machine.pending); XCTAssertNil(machine.takeDue(uptime: 1000))
        }
    }
    func testFailureInterruptionAndClosingMidTurnDoNotSleep() {
        for kind in [FinishEvent.Kind.failed, .cancelled, .closed] {
            var machine = armed(); machine.receive(event(.started), now: now + 1, uptime: 100)
            machine.receive(event(kind, offset: 2), now: now + 2, uptime: 101)
            XCTAssertNil(machine.pending); XCTAssertNil(machine.takeDue(uptime: 1000))
        }
    }
    func testStopGateNeedsIdleAndOldCandidatesDoNotTriggerAfterArming() {
        var machine = armed()
        machine.receive(event(.candidate, provider: "claude", source: "hook"), now: now + 1, uptime: 100)
        XCTAssertNil(machine.pending)
        machine.receive(event(.idle, provider: "claude", offset: 61, source: "hook"), now: now + 61, uptime: 160)
        XCTAssertNotNil(machine.pending)
        var old = FinishStateMachine()
        old.receive(event(.candidate, provider: "claude", offset: -1, source: "hook"), now: now, uptime: 90)
        XCTAssertTrue(old.enable(preferences, target: nil, now: now))
        old.receive(event(.idle, provider: "claude", offset: 60, source: "hook"), now: now + 60, uptime: 160)
        XCTAssertNil(old.pending)
    }
    func testOldGrokCancellationCannotSettleANewerTurn() {
        var machine = armed()
        machine.receive(event(.started, provider: "grok", turn: "new-turn"), now: now + 1, uptime: 100)
        machine.receive(event(.cancelled, provider: "grok", turn: "old-turn", offset: 2), now: now + 2, uptime: 101)
        XCTAssertTrue(machine.activities[FinishTarget(provider: "grok", sessionId: session)]?.busy == true)
        machine.receive(event(.completed, provider: "grok", turn: "new-turn", offset: 3), now: now + 3, uptime: 102)
        XCTAssertNotNil(machine.pending)
    }
    func testAnotherBusyAssistantAndChildrenHoldTheAction() {
        var machine = armed()
        machine.receive(event(.started, provider: "claude"), now: now + 1, uptime: 100)
        machine.receive(event(.completed, offset: 2), now: now + 2, uptime: 101)
        XCTAssertNil(machine.pending)
        machine.receive(event(.childStarted, provider: "claude", offset: 3, child: "child-1"), now: now + 3, uptime: 102)
        machine.receive(event(.completed, provider: "claude", offset: 4), now: now + 4, uptime: 103)
        XCTAssertNil(machine.pending)
        machine.receive(event(.childFinished, provider: "claude", offset: 5, child: "child-1"), now: now + 5, uptime: 104)
        XCTAssertNotNil(machine.pending)
    }
    func testSelectedSessionProviderAndSessionIdMustMatch() {
        var machine = FinishStateMachine()
        XCTAssertTrue(machine.enable(preferences, target: FinishTarget(provider: "codex", sessionId: session.uppercased()), now: now))
        machine.receive(event(.completed, provider: "claude"), now: now + 1, uptime: 100)
        XCTAssertNil(machine.pending)
        machine.receive(event(.completed, offset: 2), now: now + 2, uptime: 101)
        XCTAssertNotNil(machine.pending)
    }
    func testDuplicateTurnStaleAndFutureEventsNeverReplayAnAction() {
        var machine = armed(); let completed = event(.completed)
        machine.receive(completed, now: now + 1, uptime: 100)
        XCTAssertNotNil(machine.takeDue(uptime: 160))
        XCTAssertTrue(machine.enable(preferences, target: nil, now: now + 10))
        machine.receive(event(.completed, offset: 11), now: now + 11, uptime: 200)
        machine.receive(event(.completed, turn: "future", offset: 1000), now: now + 11, uptime: 200)
        machine.receive(event(.completed, turn: "stale", offset: -400), now: now + 11, uptime: 200)
        XCTAssertNil(machine.pending)
    }
    func testExpiredOrSuspendedCountdownCancelsRatherThanExecutingUponReturn() {
        var machine = armed(); machine.receive(event(.completed), now: now + 1, uptime: 100)
        XCTAssertNil(machine.takeDue(uptime: 10000)); XCTAssertNil(machine.arm)
    }
    func testManagedSessionsIgnoreDuplicateNativeStopNotifications() {
        var machine = armed(); machine.receive(event(.started), now: now + 1, uptime: 100)
        machine.receive(event(.completed, turn: "native-turn", offset: 2, source: "hook"), now: now + 2, uptime: 101)
        XCTAssertNil(machine.pending)
    }
    func testUnwatchedAssistantsDoNotResetOrBlockTheCountdown() {
        var prefs = preferences; prefs.providers = ["codex"]
        var machine = FinishStateMachine(); XCTAssertTrue(machine.enable(prefs, target: nil, now: now))
        machine.receive(event(.completed), now: now + 1, uptime: 100)
        let deadline = machine.pending?.deadline
        machine.receive(event(.started, provider: "grok", offset: 2), now: now + 2, uptime: 110)
        XCTAssertEqual(machine.pending?.deadline, deadline)
        machine.receive(event(.failed, provider: "claude", offset: 3), now: now + 3, uptime: 120)
        XCTAssertEqual(machine.pending?.deadline, deadline)
        XCTAssertNotNil(machine.takeDue(uptime: 160))
    }
    func testHookPayloadFiltersSubagentsAndKeepsOnlyMetadata() throws {
        let payload: [String: Any] = ["session_id": session, "hook_event_name": "Stop", "last_assistant_message": "Private reply", "prompt": "Private task", "background_tasks": [["description": "Private process"]]]
        let event = try XCTUnwrap(FinishHookPayload.event(provider: "claude", payload: payload))
        XCTAssertEqual(event.kind, .candidate); XCTAssertTrue(event.backgroundWork)
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(json.contains("Private")); XCTAssertFalse(json.contains("prompt"))
        var child = payload; child["transcript_path"] = "/home/.claude/projects/one/subagents/agent-child.jsonl"
        XCTAssertNil(FinishHookPayload.event(provider: "claude", payload: child))
        var permission = payload; permission["hook_event_name"] = "Notification"; permission["notification_type"] = "permission_prompt"
        XCTAssertEqual(FinishHookPayload.event(provider: "claude", payload: permission)?.kind, .waiting)
        XCTAssertNil(FinishHookPayload.event(provider: "codex", payload: payload))
    }
    @MainActor func testInjectedActionExecutesOnlyAfterArmingAndPreferencesChangesCancel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var executions: [FinishExecution] = []
        let controller = FinishController(directory: folder, presentUI: false) { executions.append($0) }
        XCTAssertFalse(controller.preferences.enabled); XCTAssertFalse(controller.armed)
        controller.preferences = preferences
        XCTAssertTrue(controller.arm(now: Date(timeIntervalSince1970: now)))
        controller.receive(event(.completed), now: Date(timeIntervalSince1970: now + 1), uptime: 100)
        controller.preferences.action = .none
        await controller.tick(uptime: 160); XCTAssertTrue(executions.isEmpty)
        controller.preferences.action = .sleep
        XCTAssertTrue(controller.arm(now: Date(timeIntervalSince1970: now + 2)))
        controller.receive(event(.completed, turn: "next-turn", offset: 3), now: Date(timeIntervalSince1970: now + 3), uptime: 200)
        await controller.tick(uptime: 260)
        XCTAssertEqual(executions.count, 1); XCTAssertEqual(executions.first?.action, .sleep)
        let restored = FinishController(directory: folder, presentUI: false) { _ in XCTFail("Reload must not execute an action") }
        XCTAssertTrue(restored.preferences.enabled); XCTAssertFalse(restored.armed)
    }
    @MainActor func testUnreadableSettingsArePreservedAndArmingFailsClosed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("finish-actions.json"); try Data("unreadable".utf8).write(to: file)
        let controller = FinishController(directory: folder, presentUI: false) { _ in XCTFail("Invalid settings cannot execute") }
        controller.preferences = preferences; XCTAssertFalse(controller.arm()); XCTAssertNotNil(controller.error)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unreadable")
    }
    @MainActor func testIncompleteShortcutPreferencesRemainEditableAfterRestart() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = FinishController(directory: folder, presentUI: false) { _ in XCTFail("No action is armed") }
        controller.preferences.action = .shortcut
        XCTAssertTrue(controller.preferences.valid); XCTAssertFalse(controller.preferences.ready)
        let restored = FinishController(directory: folder, presentUI: false) { _ in XCTFail("No action is armed") }
        XCTAssertNil(restored.error); restored.preferences.shortcutName = "My Shortcut"
        XCTAssertTrue(restored.preferences.ready)
    }
    @MainActor func testMonitorLeaseStopsWhenAppStopsAndDoesNotArmOnStart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = FinishController(directory: folder, presentUI: false) { _ in XCTFail("Starting the monitor cannot execute actions") }
        let store = SessionStore(directory: folder.appendingPathComponent("library"))
        controller.preferences.enabled = true; controller.preferences.action = .sleep
        controller.start(store: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("finish-monitor.json").path)); XCTAssertFalse(controller.armed)
        controller.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("finish-monitor.json").path))
    }
    func testHookWriterRequiresLiveLeaseAndRejectsInactiveMonitor() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(preferences).write(to: folder.appendingPathComponent("finish-actions.json"))
        let finished = event(.completed, offset: 0)
        try FinishFiles.write(finished, in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("finish-events").path))
        let expired = try JSONSerialization.data(withJSONObject: ["updatedAt": Date().addingTimeInterval(-20).timeIntervalSince1970])
        try expired.write(to: folder.appendingPathComponent("finish-monitor.json"))
        try FinishFiles.write(finished, in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("finish-events").path))
        try JSONSerialization.data(withJSONObject: ["updatedAt": Date().timeIntervalSince1970]).write(to: folder.appendingPathComponent("finish-monitor.json"))
        try FinishFiles.write(finished, in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("finish-events/\(finished.id).json").path))
    }
}
