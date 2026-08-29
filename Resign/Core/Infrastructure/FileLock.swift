import Foundation
import Darwin

/// Cross-process advisory lock (`flock`) so mutually distrusting processes
/// (GUI app and the scheduled worker) cannot enter the same critical section.
/// Used for the build-area lock and the config read-modify-write lock.
final class FileLock: @unchecked Sendable {
    private var fd: Int32 = -1
    private let path: String

    init(path: String) {
        self.path = path
    }

    /// Attempts a single non-blocking exclusive acquisition.
    func acquire() -> Bool {
        guard fd < 0 else { return false } // already held by this instance
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return false }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            fd = descriptor
            return true
        }
        close(descriptor)
        return false
    }

    /// Retries acquisition briefly; used for the short config critical
    /// section where the other holder is expected to release within moments.
    func acquireWithRetry(attempts: Int, delayMilliseconds: UInt32) -> Bool {
        let roundedAttempts = max(attempts, 1)
        for attempt in 0..<roundedAttempts {
            if acquire() { return true }
            if attempt < roundedAttempts - 1 {
                usleep(delayMilliseconds * 1000)
            }
        }
        return false
    }

    func release() {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}
