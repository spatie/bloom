import Foundation
import Synchronization

/// What a Bloom session needs from whatever is driving its agent.
///
/// Deliberately tiny: it is exactly the five things `TranscriptModel` calls plus the one the
/// permission prompt calls, and nothing else. Every runner has a great deal more surface than
/// this, and none of that surface is shared, because the two backends share no protocol: Claude
/// Code speaks stream-json over stdin and stdout, Codex speaks JSON-RPC over the same pipes, and
/// what they agree on is only what a conversation is.
///
/// **The backend belongs to the chat, not to the workspace.** One worktree can hold a Claude Code
/// conversation and a Codex one at the same time, editing the same files, so nothing here is
/// keyed on a workspace and nothing may assume a workspace has one of these.
///
/// Adopted on the Codex side first, on purpose. `AgentRunner` already has every member below with
/// the right shape, so conforming it is one line and no redesign, and doing that separately keeps
/// this out of a file somebody else is holding.
public protocol SessionRunner: Actor {
    /// Which CLI this is. Nonisolated because a view asks it while drawing.
    nonisolated var agentKind: AgentKind { get }

    /// Decoded events, a fresh stream per caller.
    ///
    /// Nonisolated so a view can start consuming without hopping onto the actor, and a fresh
    /// stream each time because one shared stream lets the first consumer to walk away finish it
    /// for everybody.
    nonisolated var events: AsyncStream<AgentEvent> { get }

    /// Whether the backend process is still there.
    ///
    /// Named for the process rather than for the turn because the quit path waits on this, and the
    /// two facts are not the same on both backends: Claude Code's process is killed by Stop and
    /// spawned again by the next turn, while `codex app-server` is long lived and outlives every
    /// turn on it. This member used to be `isRunning`, and the Codex side answered it with "a turn
    /// is open", so quit interrupted the turn, watched it close and concluded the process was gone
    /// while it was still running. One name, two facts, and the wrong one was being polled.
    var isProcessAlive: Bool { get }

    /// Write one user turn. Starts whatever has to be started, on first use.
    func send(_ text: String) async throws

    /// Stop the turn now, from synchronous code that cannot wait for a turn on the actor. Which is
    /// exactly when the actor is least available, because it is busy running the thing being
    /// stopped.
    ///
    /// The chat survives this on both backends and can be sent to again. What it costs differs:
    /// Claude Code has to kill its process and resume into a new one, Codex interrupts over the
    /// wire and keeps the connection, along with the grants that only exist inside it.
    nonisolated func cancelNow()

    /// The session is going away for good: quit, close, or the worktree being archived. End the
    /// turn **and** kill the process, synchronously, before the caller carries on.
    ///
    /// Separate from `cancelNow` because on one backend they are the same act and on the other
    /// they are not, and because everything that reads "the agents are gone" reads it after this.
    /// A path that only asked politely is the orphaned-children bug: children reparented to
    /// launchd on quit, and a live agent writing into a worktree `git worktree remove --force` is
    /// deleting on archive.
    nonisolated func terminateNow()

    /// Answer one permission question. Not a turn: it unblocks a turn already in flight.
    func answer(requestID: String, decision: PermissionDecision) async
}

// MARK: - Event fanout

/// Hands every consumer its own stream of the same events.
///
/// One shared `AsyncStream` is a trap that this codebase has already been caught by: cancelling
/// the task that iterates one finishes it for good, so the first consumer to walk away takes the
/// session with it. A view that stops drawing must not stop the agent, so each caller gets a
/// stream of its own and dropping it removes only that one.
///
/// A class rather than actor state, so `events` can be nonisolated and a view can attach without
/// waiting for a turn on an actor that is busy.
///
/// `Mutex<State>` rather than `NSLock` plus `@unchecked Sendable`, for the reason given on
/// `EventSink` in `AgentRunner`, which is this same shape: the subscribers and the finished flag
/// have to move together, so a stream cannot register after the fanout has already said goodbye.
public final class EventFanout<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var finished = false
    }

    private let state = Mutex(State())

    public init() {}

    public func stream() -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let registered = state.withLock { state -> Bool in
                guard !state.finished else { return false }
                state.continuations[id] = continuation
                return true
            }
            guard registered else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.unregister(id)
            }
        }
    }

    // The lock is only ever held across a dictionary access. Yielding happens after it is
    // released, because a continuation can run arbitrary code and must never do so under a lock.

    public func yield(_ element: Element) {
        for target in subscribers() { target.yield(element) }
    }

    public func finish() {
        for target in removeAll() { target.finish() }
    }

    private func unregister(_ id: UUID) {
        state.withLock { $0.continuations[id] = nil }
    }

    private func subscribers() -> [AsyncStream<Element>.Continuation] {
        state.withLock { Array($0.continuations.values) }
    }

    private func removeAll() -> [AsyncStream<Element>.Continuation] {
        state.withLock { state in
            state.finished = true
            let all = Array(state.continuations.values)
            state.continuations = [:]
            return all
        }
    }
}

// MARK: - Conformances

/// Claude Code's runner already had every member of the seam, with the right shape and the right
/// isolation, because the seam was taken from what the transcript calls on it. So conforming it is
/// one property and no edit inside the file itself.
extension AgentRunner: SessionRunner {
    public nonisolated var agentKind: AgentKind { .claudeCode }

    /// `isRunning` here has always meant the process, because this runner has only one and Stop
    /// kills it. The seam says so in its name instead of relying on a reader knowing that.
    public var isProcessAlive: Bool { isRunning }

    /// Stop and "this is over" are one act on this backend. `cancelNow` already denies the open
    /// questions in words, SIGTERMs the whole process group and SIGKILLs what ignores it, and the
    /// next turn spawns a new process with `--resume`, so there is nothing left for a second path
    /// to do. Calling both is harmless: the run is already marked cancelled and the drained asks
    /// come back empty.
    public nonisolated func terminateNow() { cancelNow() }
}
