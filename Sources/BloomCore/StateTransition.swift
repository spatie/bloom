import Foundation

/// What a lifecycle answers when it is asked to move a state.
///
/// Three answers rather than two, and the third one is the point. A machine that can only say yes
/// or no fires on correct code: a launch pass that resets every session it finds would be told no
/// for every session that was already idle, and a rule that cries wolf is a rule somebody adds an
/// exception to. `unchanged` is "legal, and there is nothing to do", which is a different sentence
/// from "that cannot happen" and has to be a different answer.
///
/// **Refusing is the safe direction.** Every state a row can be holding is one it was legally moved
/// into, so declining to move leaves it holding something true. That is why nothing here throws:
/// see `RefusedTransitions` for the whole argument, which is mostly about what an illegal
/// transition at launch should do in an app somebody uses every day.
public enum StateTransition<State: Sendable & Equatable>: Sendable, Equatable {
    /// The state moves, and the caller should carry out whatever else the event implies.
    case moves(to: State)
    /// The event is legal here and the state already says what it would say. Nothing to write,
    /// nothing to report.
    case unchanged
    /// The event cannot happen from this state. The state is left alone and the attempt is
    /// recorded. Never silently.
    case refused

    /// Whether anything has to be written.
    public var moves: Bool {
        if case .moves = self { return true }
        return false
    }

    /// The state after this, or nil when nothing moves. `unchanged` returns nil for the same
    /// reason `moves` is false for it: there is nothing to write.
    public var destination: State? {
        if case .moves(let state) = self { return state }
        return nil
    }

    /// Whether the machine said no. Callers that are about to do irreversible work off the back of
    /// a transition check this before they start, not after.
    public var isRefused: Bool { self == .refused }
}
