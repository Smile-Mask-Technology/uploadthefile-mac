import Foundation

/// An exclusive advisory lock on a file (`flock(2)`) that serialises work across processes.
///
/// The app and `uptf` each run their own ``TokenManager``; this lock is what makes them take
/// turns when they refresh the same stored credentials. The kernel drops the lock when the
/// descriptor is closed, so a process that crashes while holding it never blocks the others.
final class RefreshLock: @unchecked Sendable {
    /// The lock could not be taken before the deadline.
    struct TimedOut: Error {}

    private let state = NSLock()
    private var descriptor: Int32?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { release() }

    /// Waits up to `timeout` seconds for the lock on the file at `url`, creating the file
    /// (mode 0600) when needed. Polls instead of blocking, so the caller's thread stays free.
    ///
    /// Returns nil when the file cannot be opened or locked at all (no disk access, for example):
    /// there is nothing to wait for then, and refreshing without the lock beats not refreshing.
    /// Throws ``TimedOut`` when another holder keeps the lock for the whole `timeout`.
    static func acquire(at url: URL, timeout: TimeInterval) async throws -> RefreshLock? {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return RefreshLock(descriptor: descriptor) }
            let reason = errno
            guard reason == EWOULDBLOCK || reason == EINTR else {
                close(descriptor)
                return nil
            }
            if ContinuousClock.now >= deadline {
                close(descriptor)
                throw TimedOut()
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                close(descriptor)
                throw error
            }
        }
    }

    /// Gives the lock up. Safe to call more than once.
    func release() {
        state.lock()
        defer { state.unlock() }
        guard let descriptor else { return }
        self.descriptor = nil
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
