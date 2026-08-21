import Foundation

/// What a finished turn amounts to, from the point of view of somebody who is not looking.
public enum TurnOutcome: Sendable, Hashable {
    case finished
    case needsInput
    case failed

    public var event: NotificationEvent {
        switch self {
        case .finished: .turnFinished
        case .needsInput: .needsInput
        case .failed: .agentFailed
        }
    }
}

public extension AgentResult {
    /// Which of the three a `result` line describes, or nil when it is not worth saying anything.
    ///
    /// There is no live "the agent is waiting for you" event to hook. docs/PROTOCOL.md has no such
    /// line: in `-p --output-format stream-json` the CLI answers its own `AskUserQuestion` and the
    /// transcript shows the question read-only, after the fact. What the protocol does surface, on
    /// the `result` line that ends the turn, are the two ways a turn can end with the work not
    /// done and the reason being the user: a permission the CLI refused because there was nobody
    /// to ask, and a turn limit. Both mean the same thing to somebody in another app, which is
    /// that coming back is not optional.
    func outcome(wasCancelled: Bool) -> TurnOutcome? {
        // Stop was pressed. The CLI reports its own SIGTERM as `error_during_execution`, so
        // trusting `isError` here would tell somebody their own click was a crash.
        if wasCancelled { return nil }

        if subtype == "error_max_turns" { return .needsInput }
        if permissionDenials > 0 { return .needsInput }
        if isError { return .failed }
        return .finished
    }
}
