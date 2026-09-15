import Foundation
#if os(Linux)
import Glibc
#endif

/// How long a start waits on a held `server.lock` before calling it another server.
///
/// A restart right after a stop has to survive a lock that frees a moment later. The maintenance
/// supervisor's update handover and a systemd restart both start the new server as soon as the old
/// one has gone, and the installer's own `daemon_locked` check takes and drops the same lock to
/// ask whether a server is running. Refusing on the first `EWOULDBLOCK` turned a lock held for a
/// few milliseconds into a failed start, and a failed start after an update rolls a good update
/// back. The CI evidence is `concurrentShutdownKeepsOwnershipUntilRunnerCleanupCompletes` on
/// macOS (job 104405344404, PR #262): the replacement start, after both shutdowns had returned,
/// was refused with `EWOULDBLOCK`, and `lsof` moments later found no process with the lock file
/// open, the test process included. Who held it is not proven; that it was free again is.
///
/// Three seconds is short beside a real second server, which holds the lock for as long as it
/// runs, so ownership is still refused promptly with the same message. Only the ownership errno
/// waits: any other errno is a lock the file system cannot take, and waiting will not change it.
struct ServerLockWait: Sendable {
    var window: Duration = .seconds(3)
    var interval: Duration = .milliseconds(50)

    enum Step: Equatable {
        case acquired
        case wait(Duration)
        case refuse(Int32)
    }

    /// What to do after one attempt: `code` is nil when the lock was taken, and `elapsed` is the
    /// time since the first attempt. The last wait is cut short at the window, so the final
    /// attempt lands on the window rather than an interval past it.
    func step(code: Int32?, elapsed: Duration) -> Step {
        guard let code else { return .acquired }
        guard code == EWOULDBLOCK || code == EAGAIN, elapsed < window else { return .refuse(code) }
        return .wait(min(interval, window - elapsed))
    }

    /// Repeats `attempt` until it takes the lock or `step` refuses, and returns the refusing errno
    /// or nil. A cancelled start stops waiting and reports the last errno, rather than spinning
    /// through the rest of the window on a sleep that returns at once.
    func acquire<C: Clock>(on clock: C, attempt: () -> Int32?) async -> Int32? where C.Duration == Duration {
        let start = clock.now
        while true {
            let code = attempt()
            switch step(code: code, elapsed: start.duration(to: clock.now)) {
            case .acquired:
                return nil
            case .refuse(let refused):
                return refused
            case .wait(let delay):
                do { try await clock.sleep(for: delay) } catch { return code }
            }
        }
    }
}
