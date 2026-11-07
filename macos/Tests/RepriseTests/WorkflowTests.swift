import AppKit
import SwiftUI
import XCTest
@testable import Reprise

final class WorkflowTests: XCTestCase {
    let identifier = "a3d95531-94bb-4b72-9743-fd314b992074"

    func testDiscoversCodexMetadataWithoutConversationContent() throws {
        let json = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(identifier)\",\"cwd\":\"/tmp/Project One\"}}\n"
        let session = try XCTUnwrap(SessionDiscovery.parse(data: Data(json.utf8), model: .codex, modified: .now))
        XCTAssertEqual(session.project, "Project One")
        XCTAssertEqual(session.command, "codex resume \(identifier)")
        XCTAssertTrue(session.note.isEmpty)
        XCTAssertNotNil(session.discoveryKey)
    }

    func testClaudeSkipsIncompleteLinesAndFindsMetadata() throws {
        let json = "invalid\n{\"sessionId\":\"\(identifier)\",\"type\":\"mode\"}\n{\"sessionId\":\"\(identifier)\",\"cwd\":\"/tmp/reprise\",\"message\":{\"content\":\"private\"}}\n"
        let session = try XCTUnwrap(SessionDiscovery.parse(data: Data(json.utf8), model: .claude, modified: .now))
        XCTAssertEqual(session.command, "claude --resume \(identifier)")
        XCTAssertTrue(session.note.isEmpty)
    }

    func testTerminalRejectsInjectedCommandsAndMissingFolders() throws {
        var session = ResumeSession(model: .codex, project: "Test", projectDirectory: NSTemporaryDirectory(), note: "", command: "codex resume \(identifier); touch /tmp/unwanted", detectedAutomatically: false)
        XCTAssertThrowsError(try TerminalCommand.build(for: session))
        session.command = "codex resume \(identifier)"
        let command = try TerminalCommand.build(for: session)
        XCTAssertTrue(command.contains("&& 'codex' 'resume'"))
        XCTAssertEqual(TerminalCommand.quote("a'b $HOME"), "'a'\\''b $HOME'")
        session.projectDirectory = "/reprise-folder-that-does-not-exist"
        XCTAssertThrowsError(try TerminalCommand.build(for: session))
    }

    @MainActor func testMergePreservesEditsAndPreventsDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        var session = ResumeSession(model: .codex, project: "Imported", projectDirectory: "/tmp", note: "", command: "codex resume \(identifier)", detectedAutomatically: true)
        session.discoveryKey = session.identityKey
        store.mergeDiscovered([session, session])
        XCTAssertEqual(store.sessions.count, 1)
        var edited = try XCTUnwrap(store.sessions.first)
        edited.note = "Keep this note"
        edited.project = "My project"
        store.update(edited)
        store.mergeDiscovered([session])
        XCTAssertEqual(store.sessions.first?.note, "Keep this note")
        XCTAssertEqual(store.sessions.first?.project, "My project")
        let reopened = SessionStore(directory: directory)
        XCTAssertEqual(reopened.sessions.first?.project, "My project")
    }

    @MainActor func testUnreadableLibraryIsNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sessions.json")
        let invalid = Data("broken library".utf8)
        try invalid.write(to: file)
        let store = SessionStore(directory: directory)
        store.flush()
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    @MainActor func testAssigningCaptureMovesItIntoExistingProjectWithoutDeletingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let capture = ResumeSession(model: .codex, project: "Bildschirmfoto 2026-08-30", note: "Keep my note", command: "codex resume \(UUID().uuidString)", sourceFileName: "original.png", detectedAutomatically: false)
        store.add(capture)
        store.add(ResumeSession(model: .claude, project: "Example", projectDirectory: "/tmp/example", note: "", command: "claude --resume \(UUID().uuidString)", detectedAutomatically: true))
        store.assignDirectory("/tmp/example", to: [capture.id])
        XCTAssertEqual(ProjectLibrary.groups(store.sessions).count, 1)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions.first { $0.id == capture.id }?.note, "Keep my note")
        XCTAssertEqual(store.sessions.first { $0.id == capture.id }?.sourceFileName, "original.png")
    }

    @MainActor func testRenderLibraryPreviews() throws {
        guard let output = ProcessInfo.processInfo.environment["REPRISE_RENDER_DIR"] else { return }
        let iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.png")
        if let icon = NSImage(contentsOf: iconURL) { NSApplication.shared.applicationIconImage = icon }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        for index in 0..<18 {
            let model: AssistantModel = index % 3 == 0 ? .codex : .claude
            var session = ResumeSession(model: model, project: "Billing portal", projectDirectory: "/Users/you/Projects/billing-portal", note: index == 0 ? "Continue the payment retry timeline. Webhook tests are passing; next up is the failure state." : "", command: CommandParser.resumeCommand(model: model, identifier: index == 0 ? identifier : UUID().uuidString), createdAt: Date().addingTimeInterval(Double(-index * 3600)), detectedAutomatically: true)
            session.discoveryKey = session.identityKey
            store.add(session)
        }
        for (name, folder) in [("Studio website", "studio"), ("Search service", "search"), ("Mobile onboarding", "mobile"), ("Release monitor", "monitor")] {
            store.add(ResumeSession(model: .claude, project: name, projectDirectory: "/Users/you/Projects/\(folder)", note: "", command: "claude --resume \(UUID().uuidString)", createdAt: Date().addingTimeInterval(-86400), detectedAutomatically: true))
        }
        store.add(ResumeSession(model: .codex, project: "Screenshot 2026-08-30", note: "", command: "codex resume \(UUID().uuidString)", detectedAutomatically: false))
        store.add(ResumeSession(model: .codex, project: "internal-workspace", projectDirectory: "/Users/you/.codex/chat/internal-workspace", note: "", command: "codex resume \(UUID().uuidString)", detectedAutomatically: true))
        for (name, size, appearance) in [
            ("library-light", NSSize(width: 1180, height: 800), NSAppearance.Name.aqua),
            ("library-dark", NSSize(width: 1180, height: 800), NSAppearance.Name.darkAqua),
            ("library-dark-compact", NSSize(width: 1000, height: 720), NSAppearance.Name.darkAqua)
        ] {
            let view = NSHostingView(rootView: LibraryView(store: store, newCapture: {}).environment(\.locale, Locale(identifier: "en_US")))
            view.frame = NSRect(origin: .zero, size: size)
            view.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }
        let capture = CaptureCoordinator(store: store)
        capture.startManual()
        capture.project = "Billing portal"
        capture.projectDirectory = "/Users/developer/Projects/billing-portal"
        capture.command = "codex resume \(identifier)"
        let view = NSHostingView(rootView: CapturePopoverView(coordinator: capture, store: store, openLibrary: {}, quit: {}))
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 620)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("capture-review.png"))
        window.orderOut(nil)
    }

    func testLiveDiscoveryWhenRequested() {
        guard ProcessInfo.processInfo.environment["REPRISE_LIVE_DISCOVERY"] == "1" else { return }
        let result = SessionDiscovery.scan()
        print("Discovered metadata: Codex=\(result.sessions.filter { $0.model == .codex }.count), Claude=\(result.sessions.filter { $0.model == .claude }.count), warnings=\(result.warnings.count)")
        XCTAssertTrue(result.sessions.allSatisfy { $0.projectDirectory != nil && $0.discoveryKey != nil })
    }
}
