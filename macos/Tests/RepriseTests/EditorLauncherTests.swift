import AppKit
import XCTest
@testable import Reprise

@MainActor
final class EditorLauncherTests: XCTestCase {
    func testCustomEditorSelectionPersistsAndRejectsNonApplications() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let suite = "RepriseEditorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = try CodeEditor.application(at: fixture.application)
        let preference = EditorPreference(defaults: defaults, initialEditor: editor)
        preference.select(editor)
        XCTAssertEqual(EditorPreference(defaults: defaults).selected, editor)
        XCTAssertEqual(editor.applicationURL, fixture.application)
        XCTAssertThrowsError(try CodeEditor.application(at: fixture.project))
    }

    func testOpensFolderAsURLAndCopiesTheSelectedCommandAfterSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let editor = try CodeEditor.application(at: fixture.application)
        var opened: EditorOpenRequest?
        var copied: String?
        try await EditorLauncher.open(fixture.session, editor: editor, openApplication: { request in
            XCTAssertNil(copied)
            opened = request
        }, copyCommand: { copied = $0 })
        XCTAssertEqual(opened?.directory.path, fixture.project.path)
        XCTAssertEqual(opened?.application, fixture.application)
        XCTAssertEqual(copied, fixture.session.command)
    }

    func testFailedEditorLaunchNeverChangesClipboard() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var copied = false
        do {
            try await EditorLauncher.open(fixture.session, editor: CodeEditor.application(at: fixture.application),
                openApplication: { _ in throw CocoaError(.fileReadNoPermission) }, copyCommand: { _ in copied = true })
            XCTFail("The launch failure must be reported")
        } catch { XCTAssertFalse(copied) }
    }

    func testMissingFolderAndEditorAreReportedBeforeOpening() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let editor = try CodeEditor.application(at: fixture.application)
        var session = fixture.session
        session.projectDirectory = nil
        XCTAssertThrowsError(try EditorOpenRequest(session: session, application: fixture.application))
        session.projectDirectory = fixture.root.appendingPathComponent("missing").path
        XCTAssertThrowsError(try EditorOpenRequest(session: session, application: fixture.application))
        do {
            try await EditorLauncher.open(fixture.session, editor: nil)
            XCTFail("A missing editor must be reported")
        } catch { XCTAssertTrue(error is EditorLaunchError) }
        try FileManager.default.removeItem(at: fixture.application)
        XCTAssertNil(editor.applicationURL)
    }

    private struct Fixture {
        let root: URL
        let project: URL
        let application: URL
        let session: ResumeSession

        init() throws {
            let manager = FileManager.default
            root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            project = root.appendingPathComponent("Project 'one'; $HOME", isDirectory: true)
            application = root.appendingPathComponent("Test Editor.app", isDirectory: true)
            let contents = application.appendingPathComponent("Contents", isDirectory: true)
            let binary = contents.appendingPathComponent("MacOS/Editor")
            try manager.createDirectory(at: project, withIntermediateDirectories: true)
            try manager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try manager.setAttributes([.posixPermissions: 493], ofItemAtPath: binary.path)
            let plist = ["CFBundleIdentifier": "app.reprise.editor-test.\(UUID().uuidString)", "CFBundleName": "Test Editor", "CFBundleExecutable": "Editor", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            session = ResumeSession(model: .codex, project: "Test", projectDirectory: project.path, note: "", command: "codex resume \(UUID().uuidString)", detectedAutomatically: false)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
