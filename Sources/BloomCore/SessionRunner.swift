import Foundation

/// What a Bloom session needs from whatever is driving its agent.
///
/// Deliberately tiny: it is exactly the four things `TranscriptModel` calls plus the one the
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

    var isRunning: Bool { get }

    /// Write one user turn. Starts whatever has to be started, on first use.
    func send(_ text: String) async throws

    /// Stop now, from synchronous code that cannot wait for a turn on the actor. Which is exactly
    /// when the actor is least available, because it is busy running the thing being stopped.
    nonisolated func cancelNow()

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
public final class EventFanout<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var finished = false

    public init() {}

    public func stream() -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.lock()
            let alreadyFinished = finished
            if !alreadyFinished { continuations[id] = continuation }
            lock.unlock()

            if alreadyFinished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock(); continuations[id] = nil; lock.unlock()
            }
        }
    }

    public func yield(_ element: Element) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(element) }
    }

    public func finish() {
        lock.lock()
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for target in targets { target.finish() }
    }
}
