import XCTest
@testable import Reprise

final class ModelRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var preferences: RoutingPreferences { var p = RoutingPreferences(); p.enabled = true; return p }
    private var project: ProjectAssessment { ProjectAssessment(sourceFiles: 400, backendFiles: 240, interfaceFiles: 60, testFiles: 100, manifests: 6, earlyProject: true) }
    private var models: [RoutingModel] {
        [RoutingModel(id: "economy", name: "Economy", role: .economy, efforts: ["low", "medium", "high"]),
         RoutingModel(id: "everyday", name: "Everyday", role: .balanced, efforts: ["low", "medium", "high"]),
         RoutingModel(id: "strong", name: "Strong", role: .strong, efforts: ["low", "medium", "high", "max"]),
         RoutingModel(id: "frontier", name: "Frontier", role: .frontier, efforts: ["low", "medium", "high", "max"])]
    }
    private func window(_ id: String = "weekly", used: Double = 10, reset: Double = 86_400, minutes: Double = 10_080, observed: Double = 0, modelIDs: [String] = [], special: Bool = false) -> QuotaWindow {
        QuotaWindow(id: id, label: id, usedPercent: used, resetsAt: now.addingTimeInterval(reset), durationMinutes: minutes, modelIDs: modelIDs, specialAllowance: special, observedAt: now.addingTimeInterval(observed))
    }
    private func state(_ windows: [QuotaWindow]? = nil) -> ProviderRoutingState {
        ProviderRoutingState(provider: .codex, models: models, windows: windows ?? [window()], observedAt: now, subscription: true)
    }
    private func choose(_ windows: [QuotaWindow]? = nil, hint: WorkKind = .foundation, prefs: RoutingPreferences? = nil) -> RoutingDecision {
        ModelRouter.decide(project: project, state: state(windows), preferences: prefs ?? preferences, hint: hint, now: now)
    }

    func testDisabledFeatureLeavesLaunchUntouched() throws {
        let result = choose(prefs: RoutingPreferences())
        XCTAssertNil(result.model); XCTAssertTrue(result.arguments(provider: .codex).isEmpty)
    }
    func testBackendFoundationAndUIUseDifferentEffortWithoutDefaultMax() {
        XCTAssertEqual(choose().model?.id, "frontier")
        XCTAssertEqual(choose().effort, "high")
        XCTAssertEqual(choose(hint: .interface).model?.id, "strong")
        XCTAssertEqual(choose(hint: .interface).effort, "medium")
    }
    func testWeeklyConstraintWinsOverSoonResettingShortWindow() {
        let windows = [window("five", used: 5, reset: 60, minutes: 300), window(used: 87)]
        let result = choose(windows, hint: .interface)
        XCTAssertEqual(result.model?.id, "economy"); XCTAssertEqual(result.effort, "low"); XCTAssertFalse(result.boosted)
    }
    func testPacingConservesWhenWeeklyUsageRunsAheadOfTime() {
        let result = choose([window(used: 50, reset: 6 * 86400)], hint: .foundation)
        XCTAssertTrue(result.constrained); XCTAssertEqual(result.model?.id, "strong"); XCTAssertEqual(result.effort, "medium")
    }
    @MainActor func testManagedDescriptorPreservesSessionAndQuotesDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Reprise O'Brien \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let routing = RoutingStore(directory: folder.appendingPathComponent("settings")); routing.preferences.enabled = true
        let session = ResumeSession(model: .codex, project: "Example", projectDirectory: folder.path, note: "", command: "codex resume 8d4b841b-1552-4b11-9a32-33b9205b836a", detectedAutomatically: true)
        XCTAssertTrue(routing.usesManagedSession(session))
        let args = try ManagedSessionCommand.arguments(for: session, routing: routing, runner: URL(fileURLWithPath: "/Applications/Reprise.app/Contents/MacOS/reprise-agent"))
        let data = try XCTUnwrap(Data(base64Encoded: args[3]))
        let request = try JSONDecoder().decode(ManagedSessionRequest.self, from: data)
        XCTAssertEqual(request.sessionId, session.sessionIdentifier); XCTAssertEqual(request.directory, folder.path)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Token"))
        routing.preferences.continuous = false; XCTAssertFalse(routing.usesManagedSession(session))
    }
    func testSoonResetCanUpgradeOnlyWithHeadroomInOtherWindows() {
        let result = choose([window("five", used: 10, reset: 60, minutes: 300), window(used: 15)], hint: .interface)
        XCTAssertEqual(result.model?.id, "frontier"); XCTAssertEqual(result.effort, "high"); XCTAssertTrue(result.boosted)
        XCTAssertFalse(choose([window("five", used: 10, reset: 60, minutes: 300), window(used: 70)], hint: .interface).boosted)
    }
    func testResetNeverReplenishesAnExpiredSnapshotLocally() {
        let result = choose([window(used: 100, reset: -1)])
        XCTAssertNil(result.model?.requiresSpecialAllowance == true ? result.model : nil)
        XCTAssertTrue(result.constrained); XCTAssertEqual(result.effort, "low"); XCTAssertFalse(result.boosted)
    }
    func testExhaustedSharedUsageBlocksNewLaunch() {
        let result = choose([window(used: 100)])
        XCTAssertTrue(result.blocked); XCTAssertNil(result.model)
    }
    func testStaleOrUnknownUsageNeverUpgrades() {
        for windows in [[], [window(observed: -301)], [window(used: .nan)]] {
            let result = choose(windows)
            XCTAssertEqual(result.model?.id, "everyday"); XCTAssertEqual(result.effort, "low"); XCTAssertFalse(result.boosted)
        }
    }
    func testMaxNeedsExplicitEarlyBackendExceptionAndLargeHeadroom() {
        var prefs = preferences; prefs.allowFoundationMax = true
        XCTAssertEqual(choose(prefs: prefs).effort, "max")
        XCTAssertEqual(choose(hint: .interface, prefs: prefs).effort, "medium")
        XCTAssertNotEqual(choose([window(used: 30)], prefs: prefs).effort, "max")
        XCTAssertNotEqual(choose([window("five", used: 5, reset: 60, minutes: 300), window()], prefs: prefs).effort, "max")
        var established = project; established.earlyProject = false
        XCTAssertNotEqual(ModelRouter.decide(project: established, state: state(), preferences: prefs, hint: .foundation, now: now).effort, "max")
    }
    func testFableNeedsItsOwnAllowanceAndSharedQuota() {
        var s = state(); s.provider = .claude
        s.models[3].id = "claude-fable-5-2"; s.models[3].requiresSpecialAllowance = true
        var prefs = preferences; prefs.useFableAllowance = true
        func result(_ windows: [QuotaWindow], subscription: Bool = true) -> RoutingDecision {
            var snapshot = s; snapshot.windows = windows; snapshot.subscription = subscription
            return ModelRouter.decide(project: project, state: snapshot, preferences: prefs, hint: .foundation, now: now)
        }
        let fable = window("fable", modelIDs: ["claude-fable-5-2"], special: true)
        XCTAssertEqual(result([window(), fable]).model?.id, "claude-fable-5-2")
        XCTAssertNotEqual(result([window()]).model?.id, "claude-fable-5-2")
        XCTAssertNotEqual(result([window(), window("fable", used: 100, modelIDs: ["claude-fable-5-2"], special: true)]).model?.id, "claude-fable-5-2")
        XCTAssertNotEqual(result([window(), window("fable", observed: -301, modelIDs: ["claude-fable-5-2"], special: true)]).model?.id, "claude-fable-5-2")
        XCTAssertNotEqual(result([window(used: 90), fable]).model?.id, "claude-fable-5-2")
        XCTAssertNotEqual(result([window(), fable], subscription: false).model?.id, "claude-fable-5-2")
    }
    func testModelSpecificExhaustionFallsBackWithoutBlockingOtherModels() {
        let result = choose([window(), window("architecture", used: 100, modelIDs: ["frontier"])])
        XCTAssertEqual(result.model?.id, "strong"); XCTAssertFalse(result.blocked)
    }
    func testOnlyAdvertisedEffortIsUsed() {
        var s = state(); s.models = [RoutingModel(id: "limited", name: "Limited", role: .strong, efforts: ["low", "medium"])]
        let result = ModelRouter.decide(project: project, state: s, preferences: preferences, hint: .foundation, now: now)
        XCTAssertEqual(result.effort, "medium")
        s.models[0].efforts = ["max"]
        XCTAssertNil(ModelRouter.decide(project: project, state: s, preferences: preferences, hint: .interface, now: now).model)
    }
    func testInvalidModelCannotInjectArguments() {
        var s = state(); s.models = [RoutingModel(id: "good; touch /tmp/attack", name: "Invalid", role: .frontier, efforts: ["high"])]
        XCTAssertNil(ModelRouter.decide(project: project, state: s, preferences: preferences, now: now).model)
    }
    func testLaunchArgumentsKeepTheSessionIDAndStoredCommand() throws {
        let folder = FileManager.default.temporaryDirectory
        let session = ResumeSession(model: .codex, project: "Example", projectDirectory: folder.path, note: "", command: "codex resume 8d4b841b-1552-4b11-9a32-33b9205b836a", detectedAutomatically: true)
        let original = session.command
        let result = choose()
        let command = try TerminalCommand.build(for: session, decision: result)
        XCTAssertTrue(command.contains("'--model' 'frontier'"))
        XCTAssertTrue(command.contains("'model_reasoning_effort=\"high\"'"))
        XCTAssertEqual(session.command, original)
        XCTAssertThrowsError(try TerminalCommand.build(for: session, decision: choose([window(used: 100)])))
    }
    func testClaudeParserNeverGuessesAnUnknownFableField() {
        let payload: [String: Any] = ["seven_day": ["utilization": 10.0, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970],
            "seven_day_internal": ["utilization": 25.0, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970]]
        let unknown = RoutingPayload.claude(payload, subscription: true, fableKey: nil, now: now)
        XCTAssertTrue(unknown.windows.allSatisfy { !$0.specialAllowance })
        let selected = RoutingPayload.claude(payload, subscription: true, fableKey: "seven_day_internal", now: now)
        XCTAssertEqual(selected.windows.first { $0.specialAllowance }?.modelIDs, ["claude-fable-5-2"])
    }
    func testCodexParserUsesAvailableCatalogAndAllQuotaWindows() {
        let catalog: [String: Any] = ["data": [["model": "gpt-6.1-sol", "displayName": "Sol", "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "ultra"]]],
            ["model": "not-enabled", "hidden": true, "supportedReasoningEfforts": [["reasoningEffort": "high"]]]]]
        let limits: [String: Any] = ["ordinaryUsageAllowed": true, "rateLimitsByLimitId": ["codex": ["planType": "plus", "primary": ["usedPercent": 3.0, "windowDurationMins": 300, "resetsAt": now.addingTimeInterval(60).timeIntervalSince1970], "secondary": ["usedPercent": 75.0, "windowDurationMins": 10080, "resetsAt": now.addingTimeInterval(3600).timeIntervalSince1970]]]]
        let result = RoutingPayload.codex(models: catalog, usage: limits, now: now)
        XCTAssertEqual(result.models.map(\.id), ["gpt-6.1-sol"])
        XCTAssertEqual(result.models.first?.efforts, ["low"])
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertTrue(result.subscription)
    }
    func testProjectAnalysisSkipsDependenciesAndSymlinksAndDetectsUI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Screen.tsx"))
        try Data().write(to: root.appendingPathComponent("node_modules/pkg/server.py"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: FileManager.default.temporaryDirectory)
        let assessment = ProjectAssessor.assess(directory: root)
        XCTAssertEqual(assessment.sourceFiles, 1); XCTAssertEqual(assessment.interfaceFiles, 1); XCTAssertEqual(assessment.backendFiles, 0)
        XCTAssertEqual(assessment.workKind(hint: .automatic), .interface)
        XCTAssertEqual(assessment.workKind(hint: .foundation), .foundation)
    }
    @MainActor func testRoutingSettingsAreOptInAndNeverOverwriteUnreadableData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RoutingStore(directory: folder)
        XCTAssertFalse(store.preferences.enabled)
        store.preferences.enabled = true; store.preferences.reservePercent = 25
        let loaded = RoutingStore(directory: folder)
        XCTAssertTrue(loaded.preferences.enabled); XCTAssertEqual(loaded.preferences.reservePercent, 25)
        let file = folder.appendingPathComponent("model-routing.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("accessToken")); XCTAssertFalse(text.contains("refreshToken"))
        try Data("corrupt".utf8).write(to: file)
        let broken = RoutingStore(directory: folder); broken.preferences.enabled = true
        XCTAssertNotNil(broken.storageError); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "corrupt")
    }
}
