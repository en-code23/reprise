import Darwin
import Foundation

/// The kernel releases this lock even if Reprise crashes. Keep the file in place:
/// deleting it would let another process lock a different inode at the same path.
final class SingleInstanceLock {
    private let descriptor: Int32

    /// Returns nil when another process owns the lock; other failures are errors.
    init?(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }
}
