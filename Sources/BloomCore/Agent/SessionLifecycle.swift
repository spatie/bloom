import Foundation

/// Everything that can move a chat's `SessionState`.
///
/// Two runners speak two protocols and both write this column: `AgentRunner` for Claude Code's
/// stream-json and `CodexRunner` for Codex's JSON-RPC. Thirteen assignments between them, in two
/// dialects, and the rules they shared were written as comments and hand-rolled guards next to
/// each one. `AgentRunner` still carries the clearest of those, next to the write it protects:
/// "the session must not now be marked as waiting for a question that is already settled". That
/// sentence is a transition table with one row in it, and this file is the rest of the table.
///
/// **Where recovery fits.** `appRelaunched` is a case here, not an exception around here. A
/// session left `running` or `waiting` when the app died is doing neither now, and `waiting` is the
/// sharper half: a blocked agent holds its turn open until somebody answers and the CLI puts no
/// timer on that, so a session that came back still claiming to be waiting drew a raised hand in
/// the sidebar, a badge on the Dock, and four live buttons that wrote into a closed pipe. It is a
/// legal transition, it happens once a launch, and `Store.resetRunningSessions` builds its `WHERE`
/// clause out of this table so the bulk pass and the machine cannot drift apart.
public enum SessionEvent: Sendable, Hashable {
    /// A user turn went to the agent's stdin.
    case turnStarted
    /// The agent asked to do something and is holding the turn open until somebody answers.
    case blocked
    /// The last open question was answered, so the turn is moving again.
    case unblocked
    /// A result arrived for the turn.
    case turnFinished(isError: Bool)
    /// The user pressed stop.
    case cancelled
    /// The process ended with nothing left to report and nothing wrong.
    case processExited
    /// The process ended without ever reporting a result, and said so with its exit status.
    case processFailed
    /// The app was started again, so nothing the last launch left mid turn is mid turn now.
    /// See `Store.resetRunningSessions`.
    case appRelaunched
}

public extension SessionState {
    /// Whether a turn is open, in the sense the CLI means: the process has been handed something
    /// and has not finished with it. The two states an interrupted launch has to clean up.
    var isMidTurn: Bool { self == .running || self == .waiting }

    /// Where this state goes when the event happens, and nowhere else.
    ///
    /// The refusals, and what each is for:
    ///
    /// **`blocked` from anything but a turn in flight.** This is the guard `AgentRunner` writes by
    /// hand. Two routes race to answer a permission question, the stored project grants and the
    /// person clicking, and the loser used to write `waiting` for a decision that had already been
    /// made: the session sat marked as blocked on nothing, and the CLI discarded the second answer
    /// as a request id mismatch.
    ///
    /// **`cancelled` from a state with no turn open.** A stop that lands on a session that has
    /// already finished files a turn that ended normally as one the user abandoned, and the
    /// transcript then says so for ever. Stop is fire and forget from a button that cannot await,
    /// so the request reaches the actor whenever the actor gets to it, which is exactly the window
    /// where this happens.
    ///
    /// **`turnStarted` from `waiting`.** The agent is blocked on a question and is not reading its
    /// stdin for anything else. A turn sent into that goes nowhere, and marking the session
    /// `running` for it hides the raised hand that is the only thing telling the user why nothing
    /// is happening. This is the one refusal that leaves a state a caller may disagree with, which
    /// is why it is worth being explicit: `waiting` is still the truth, and the composer is
    /// disabled in that state precisely so this never has to fire.
    ///
    /// **`turnFinished` outside a turn is NOT refused.** SIGTERM makes the CLI report
    /// `error_during_execution` on its way out, so a result after a stop is the ordinary case, and
    /// a result arriving just behind the process exit that already filed the turn is the same
    /// shape. Both runners used to carry a `cancelled ? .cancelled : ...` ternary to say the first
    /// of those at the call site; saying it here means neither has to. A machine that refused here
    /// would fire on the happy path, which is how a rule stops being believed.
    func transition(on event: SessionEvent) -> StateTransition<SessionState> {
        switch event {
        case .turnStarted:
            switch self {
            case .running: return .unchanged
            case .waiting: return .refused
            case .idle, .failed, .cancelled: return .moves(to: .running)
            }

        case .blocked:
            switch self {
            case .running: return .moves(to: .waiting)
            case .waiting: return .unchanged
            case .idle, .failed, .cancelled: return .refused
            }

        // Never refused. Answering a question when nothing is blocked is a no-op, and the runners
        // reach this from paths that also run on the way out of a cancelled turn.
        case .unblocked:
            return self == .waiting ? .moves(to: .running) : .unchanged

        case .turnFinished(let isError):
            guard isMidTurn else { return .unchanged }
            return .moves(to: isError ? .failed : .idle)

        case .cancelled:
            switch self {
            case .running, .waiting: return .moves(to: .cancelled)
            case .cancelled: return .unchanged
            case .idle, .failed: return .refused
            }

        case .processExited:
            return isMidTurn ? .moves(to: .idle) : .unchanged

        case .processFailed:
            return isMidTurn ? .moves(to: .failed) : .unchanged

        // Recovery, and legal from every state. What the last launch left behind is not this
        // launch's business to argue with.
        case .appRelaunched:
            return isMidTurn ? .moves(to: .idle) : .unchanged
        }
    }
}

public extension Session {
    /// Move the session state, and stamp the moment it moved. The only way in.
    ///
    /// `updatedAt` is not a separate chore a caller remembers. It is this runner's statement about
    /// when the turn last moved, it is what `TranscriptModel.refreshSession` reads to decide
    /// whether the row it is holding still describes the last turn, and a state change written
    /// without it is a change nothing downstream notices. That is the whole argument for this
    /// method existing: the state and the work that goes with it are one statement.
    ///
    /// Mutating a value, not writing a row. The runners call it twice for one event, once on the
    /// copy they hold and once inside `Store.update(sessionID:)`, so the durable row runs the
    /// machine against what is actually stored rather than against a copy the runner has been
    /// carrying since the workspace was opened.
    @discardableResult
    mutating func apply(_ event: SessionEvent, at date: Date = Date()) -> StateTransition<SessionState> {
        let outcome = state.transition(on: event)
        switch outcome {
        case .refused:
            RefusedTransitions.record(machine: "session", from: state.rawValue, event: event.name)
        case .unchanged:
            break
        case .moves(let next):
            state = next
            updatedAt = date
        }
        return outcome
    }
}

extension SessionEvent {
    /// What a refusal calls this event. The case name, so the log line and the source agree.
    var name: String {
        switch self {
        case .turnStarted: "turnStarted"
        case .blocked: "blocked"
        case .unblocked: "unblocked"
        case .turnFinished(let isError): isError ? "turnFinished(error)" : "turnFinished"
        case .cancelled: "cancelled"
        case .processExited: "processExited"
        case .processFailed: "processFailed"
        case .appRelaunched: "appRelaunched"
        }
    }
}
