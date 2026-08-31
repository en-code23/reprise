import XCTest
@testable import Reprise

final class CommandParserTests: XCTestCase {
    func testCanonicalizesLegacyCodexCommand() {
        XCTAssertEqual(
            CommandParser.canonicalize(#"codex --resume "019cba47-918e""#),
            "codex resume 019cba47-918e"
        )
    }

    func testParsesUnquotedClaudeCommand() {
        let parsed = CommandParser.parse("$ claude resume 4d4e9441-f029-4275")

        XCTAssertEqual(parsed.model, .claude)
        XCTAssertEqual(parsed.command, "claude resume 4d4e9441-f029-4275")
        XCTAssertTrue(parsed.wasDetected)
    }

    func testDetectsDirectoryFromPrompt() {
        let parsed = CommandParser.parse(
            "enver@mac ~/Developer/billing-portal % codex resume 019cba47-918e"
        )

        XCTAssertEqual(parsed.projectDirectory, "~/Developer/billing-portal")
        XCTAssertEqual(parsed.command, "codex resume 019cba47-918e")
    }

    func testDetectsDirectoryFromPwdOutput() {
        let text = "$ pwd\n/Users/enver/Developer/reprise\n$ grok resume session_b97d0043"

        XCTAssertEqual(
            CommandParser.detectProjectDirectory(in: text),
            "/Users/enver/Developer/reprise"
        )
    }

    func testDetectsStandaloneDirectoryBeforeCommand() {
        let text = "~/Developer/reprise\n$ codex resume 019cba47-918e"

        XCTAssertEqual(
            CommandParser.detectProjectDirectory(in: text),
            "~/Developer/reprise"
        )
    }
}
