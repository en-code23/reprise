import AppKit
import XCTest
@testable import Reprise

final class TerminalPreferenceTests: XCTestCase {
    func testDefaultAndSavedTerminalPreference() throws {
        let suite = "RepriseTerminalTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TerminalPreference.selected(in: defaults), .terminal)
        defaults.set(TerminalApp.ghostty.rawValue, forKey: TerminalPreference.key)
        XCTAssertEqual(TerminalPreference.selected(in: defaults), .ghostty)
        defaults.set("unknown-app", forKey: TerminalPreference.key)
        XCTAssertEqual(TerminalPreference.selected(in: defaults), .terminal)
    }

    @MainActor func testInstalledTerminalScriptsCompileWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["REPRISE_COMPILE_TERMINALS"] == "1" else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for terminal in TerminalApp.allCases where terminal.applicationURL != nil {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", directory.appendingPathComponent(terminal.rawValue + ".scpt").path, "-e", terminal.appleScript]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(terminal.name): \(String(decoding: data, as: UTF8.self))")
            print("Validated scripting dictionary: \(terminal.name)")
        }
    }
}
