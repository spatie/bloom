import Foundation
import Synchronization

/// What a turn is, from outside the actor.
///
/// Stop is pressed from synchronous main-actor code, and the actor at that moment is busy running
/// the thing being stopped. The intent has to be recorded where it can be read without waiting.
///
/// `Mutex<State>` rather than `NSLock` plus `@unchecked Sendable`, for the reason given on
/// `EventFanout` in `SessionRunner`: `@unchecked` is a promise the compiler cannot check, and
/// the two fields below have to move together.
final class CodexTurnHandle: Sendable {
    struct Stopped: Sendable {
        let generation: UInt64
        let turnID: String?
    }

    private struct State {
        var current: String?
        var lastTurnID: String?
        var cancelled = false
        var generation: UInt64 = 0
        var replacement: UUID?
        var intent = UUID()
    }

    private let state = Mutex(State())

    var turnID: String? { state.withLock(\.current) }

    /// The turn a message may be **steered into**, which is one that is open and has not been
    /// stopped.
    ///
    /// **A stopped turn keeps its id for a moment and is over all the same.** `end()` runs on the
    /// `turn/completed` the interrupt produces, so between `cancelNow` and that notification
    /// arriving `current` still names a turn nobody is running. Steering into it is the wrong call
    /// whatever the server answers, and it cost the one thing Stop is for: the next message went
    /// into the dead turn instead of starting a new one on the same connection, which is what
    /// keeps the grants the person has already given. `CodexRunnerTests`
    /// `stopInterruptsTheTurnAndLeavesTheServerRunning` is that bug written down, at one handshake
    /// and two turns.
    ///
    /// Both fields under one lock, which is the whole reason this is a `Mutex<State>`: reading
    /// them separately is two answers that can disagree about the same instant.
    var steerableTurnID: String? {
        state.withLock { $0.cancelled ? nil : $0.current }
    }

    var wasCancelled: Bool { state.withLock(\.cancelled) }
    var generation: UInt64 { state.withLock(\.generation) }
    var intent: UUID { state.withLock(\.intent) }

    /// The old turn stops owning the busy state as soon as the owner asks for its replacement,
    /// not only when the server eventually returns a new id.
    func prepareReplacement() -> UUID? {
        state.withLock {
            guard $0.cancelled || $0.current == nil else { return nil }
            let token = UUID()
            $0.replacement = token
            $0.intent = token
            return token
        }
    }

    func finishReplacement(_ token: UUID?) {
        state.withLock {
            if $0.replacement == token { $0.replacement = nil }
        }
    }

    func acceptsTerminal(turnID: String, intent: UUID? = nil) -> Bool {
        state.withLock {
            if let intent, intent != $0.intent { return false }
            if $0.replacement != nil, $0.lastTurnID == turnID { return false }
            return $0.current == nil || $0.current == turnID
        }
    }

    func check(_ generation: UInt64) throws {
        guard state.withLock({ $0.generation == generation }) else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func begin(turnID: String, generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.generation == generation else { return false }
            state.current = turnID
            state.lastTurnID = turnID
            state.cancelled = false
            state.replacement = nil
            return true
        }
    }

    @discardableResult
    func markCancelled() -> Stopped {
        state.withLock {
            $0.generation &+= 1
            $0.cancelled = true
            return Stopped(generation: $0.generation, turnID: $0.current)
        }
    }

    func end() {
        state.withLock { $0.current = nil }
    }
}
