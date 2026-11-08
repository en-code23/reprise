import XCTest
@testable import Reprise

final class SingleInstanceLockTests: XCTestCase {
    func testOnlyOneOwnerAndReleasesWhenOwnerIsReleased() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var first: SingleInstanceLock? = try XCTUnwrap(SingleInstanceLock(at: url))
        try withExtendedLifetime(first) {
            XCTAssertNil(try SingleInstanceLock(at: url))
        }
        first = nil
        let replacement = try XCTUnwrap(SingleInstanceLock(at: url))
        try withExtendedLifetime(replacement) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNil(try SingleInstanceLock(at: url))
        }
    }

    func testInvalidLockLocationFailsInsteadOfAllowingAnotherInstance() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("instance.lock")
        XCTAssertThrowsError(try SingleInstanceLock(at: url))
    }
}
