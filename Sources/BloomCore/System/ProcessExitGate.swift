import Foundation
import Synchronization

/// Waits for a child process to exit, without caring whether it has already.
///
/// **The bug this exists for.** `Shell.run` and `Git.runRaw` both did the obvious thing: call
/// `process.run()`, get the pipes and the stdin write out of the way, and then suspend on a
/// continuation resumed from `terminationHandler`. Foundation calls that handler when the child
/// exits, and only if it is installed at the time. A child that has already exited by the time the
/// line setting it is reached never calls it, the continuation is never resumed, and the awaiting
/// task hangs for the lifetime of the app. `withTaskCancellationHandler` cannot rescue it either,
/// because its `onCancel` guards on `isRunning` and the process is long gone.
///
/// The window is small and it is not theoretical: it is every fast command under load, which on
/// this app means most of them. `git rev-parse`, `git status` on a small worktree, `gh --version`.
/// Most local git calls pass no timeout, so there is nothing to break the hang afterwards.
///
/// So the handler is installed **before** `run()`, which is what `StreamingProcess` has always
/// done, and this holds the little bit of state that makes that safe: whoever gets there first
/// wins. If the child exits before anybody waits, the exit is remembered and `wait()` returns at
/// once. If somebody waits first, the continuation is parked and the exit resumes it.
final class ProcessExitGate: Sendable {
    private struct State {
        var hasExited = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// Called from `terminationHandler`, possibly on a Foundation thread, possibly before anybody
    /// is waiting and possibly more than once. Resuming a continuation twice is a crash, so the
    /// waiter is taken out of the state under the lock and resumed outside it.
    func signal() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.hasExited = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Returns when the child has exited, including when it exited before this was called.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyExited = state.withLock { state -> Bool in
                if state.hasExited { return true }
                state.waiter = continuation
                return false
            }
            // Outside the lock: resuming a continuation can run arbitrary code on this thread.
            if alreadyExited { continuation.resume() }
        }
    }
}
