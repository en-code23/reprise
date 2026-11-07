import XCTest
@testable import Reprise

final class SessionOriginTests: XCTestCase {
    private let id = "ffad4101-cab5-423f-a316-9bcb774b2001"

    func testCodexDesktopMarkerWinsOverSharedVSCodeSource() {
        XCTAssertEqual(SessionOriginDetector.codex(originator: "Codex Desktop", source: "vscode").origin, .desktopApp)
        XCTAssertEqual(SessionOriginDetector.codex(originator: "codex-tui", source: "vscode").origin, .cli)
        XCTAssertEqual(SessionOriginDetector.codex(originator: "codex_cli_rs", source: "cli").origin, .cli)
    }

    func testAmbiguousSourceAndMissingFieldsStayUnknown() {
        XCTAssertEqual(SessionOriginDetector.codex(originator: nil, source: "vscode").origin, .unknown)
        XCTAssertEqual(SessionOriginDetector.codex(originator: nil, source: nil).origin, .unknown)
        XCTAssertEqual(SessionOriginDetector.claude(entrypoints: ["new-client"]).origin, .unknown)
    }

    func testClaudeSeparatesDesktopCLIAndSDK() {
        XCTAssertEqual(SessionOriginDetector.claude(entrypoints: ["claude-desktop"]).origin, .desktopApp)
        XCTAssertEqual(SessionOriginDetector.claude(entrypoints: ["cli"]).origin, .cli)
        XCTAssertEqual(SessionOriginDetector.claude(entrypoints: ["sdk-cli", "sdk-py"]).origin, .sdk)
        XCTAssertEqual(SessionOriginDetector.claude(entrypoints: ["cli", "claude-desktop"]).origin, .multiple)
    }

    func testClaudeFindsSourceAfterDirectoryRecordAndIgnoresSidechain() throws {
        let data = Data("""
        {"sessionId":"\(id)","cwd":"/tmp/project","type":"user"}
        {"sessionId":"\(id)","cwd":"/tmp/project","entrypoint":"claude-desktop","type":"user"}
        {"sessionId":"\(id)","isSidechain":true,"entrypoint":"sdk-py"}
        """.utf8)
        let session = try XCTUnwrap(SessionDiscovery.parse(data: data, model: .claude, modified: .now))
        XCTAssertEqual(session.origin, .desktopApp)
        XCTAssertEqual(session.sourceEvidence, ["entrypoint: claude-desktop"])
    }

    func testFilterKeepsOneProjectAndOnlyMatchingSources() throws {
        var app = sample(); app.detectedOrigin = .desktopApp
        var cli = sample(); cli.detectedOrigin = .cli
        let groups = ProjectLibrary.groups([app, cli], origin: .desktopApp)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sessions.count, 1)
        XCTAssertEqual(groups.first?.latest.origin, .desktopApp)
    }

    @MainActor func testSyncEnrichesOldRecordsAndPreservesManualOverride() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        var original = sample()
        original.note = "Preserve this"
        store.add(original)
        var discovered = original
        discovered.discoveryKey = discovered.identityKey
        discovered.detectedOrigin = .desktopApp
        discovered.sourceEvidence = ["originator: Codex Desktop"]
        store.mergeDiscovered([discovered])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.origin, .desktopApp)
        var edited = try XCTUnwrap(store.sessions.first)
        edited.originOverride = .cli
        store.update(edited)
        store.mergeDiscovered([discovered])
        let reopened = SessionStore(directory: directory)
        XCTAssertEqual(reopened.sessions.first?.origin, .cli)
        XCTAssertEqual(reopened.sessions.first?.detectedOrigin, .desktopApp)
        XCTAssertEqual(reopened.sessions.first?.note, "Preserve this")
    }

    func testLegacyJSONWithoutSourceStillDecodes() throws {
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(sample())) as? [String: Any])
        json.removeValue(forKey: "detectedOrigin")
        json.removeValue(forKey: "originOverride")
        json.removeValue(forKey: "sourceEvidence")
        let decoded = try JSONDecoder().decode(ResumeSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.origin, .unknown)
    }

    @MainActor func testDuplicateCaptureDoesNotEraseDetectedSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        var discovered = sample()
        discovered.detectedOrigin = .desktopApp
        discovered.discoveryKey = discovered.identityKey
        discovered.sourceEvidence = ["originator: Codex Desktop"]
        store.add(discovered)
        store.add(sample())
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.origin, .desktopApp)
        XCTAssertEqual(store.sessions.first?.discoveryKey, discovered.discoveryKey)
    }

    private func sample() -> ResumeSession {
        ResumeSession(model: .codex, project: "Project", projectDirectory: "/tmp/project", note: "", command: "codex resume \(id)", detectedAutomatically: true)
    }
}
