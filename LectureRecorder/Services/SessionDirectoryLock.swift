import Darwin
import Foundation
import Synchronization

/// An exclusive, non-blocking advisory lock on one session directory,
/// proving that a live process owns that session's recording lifecycle.
///
/// The lock is a `flock(LOCK_EX | LOCK_NB)` on a descriptor for the session
/// directory itself — no lock file or other artifact is ever created. The
/// kernel releases it when the descriptor closes, including when the owning
/// process crashes or is killed, so a session whose lock can be acquired has
/// no live owner. The descriptor is opened `O_CLOEXEC`, so spawned helper
/// processes (such as the Whisper worker) never inherit — and so never
/// prolong — the lock.
///
/// RAII: the lock is held from a successful `tryAcquire` until `release()`
/// or deinitialization, whichever comes first. `release()` is idempotent.
nonisolated final class SessionDirectoryLock: Sendable {
    nonisolated enum AcquireOutcome {
        /// The caller now owns the lock.
        case acquired(SessionDirectoryLock)
        /// Another live descriptor holds the lock.
        case busy
        /// The directory could not be opened or locked. Callers must treat
        /// this as "ownership unknown" and fail closed.
        case failed(errno: Int32)
    }

    private let descriptor: Mutex<Int32?>

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    deinit {
        release()
    }

    /// Opens `directory` without following a symlink and attempts the
    /// exclusive lock without blocking.
    static func tryAcquire(directory: URL) -> AcquireOutcome {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return .failed(errno: errno)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockErrno = errno
            close(fd)
            return lockErrno == EWOULDBLOCK ? .busy : .failed(errno: lockErrno)
        }
        return .acquired(SessionDirectoryLock(descriptor: fd))
    }

    /// Whether this instance still holds the lock.
    var isHeld: Bool {
        descriptor.withLock { $0 != nil }
    }

    /// Releases the lock by closing the descriptor. Safe to call repeatedly.
    func release() {
        let fd: Int32? = descriptor.withLock { value in
            defer { value = nil }
            return value
        }
        if let fd {
            close(fd)
        }
    }
}
