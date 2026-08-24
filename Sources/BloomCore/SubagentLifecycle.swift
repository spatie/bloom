import Foundation

/// Where a subagent is in its life.
///
/// A pair of bools would have said the same thing in the sidebar and would have been wrong about
/// two of the four moments that matter. `isRunning == false, didFail == false` is both "it worked"
/// and "no line about it has arrived yet", and a subagent whose result never lands (the app quit,
/// the CLI was killed) would read as a success for as long as the row was on screen. So it is a
/// state, it starts at `running` because the line that creates a row is the line that says it has
/// started, and it only ever moves forwards.
///
/// `RawRepresentable` with a `String` for symmetry with `SetupState` and `WorkspaceStatus`, not
/// because anything stores it. Nothing does: see `SubagentRoster` for why there is no table.
public enum SubagentState: String, Sendable, Hashable, CaseIterable, Codable {
    /// Spawned, and the last thing the CLI said about it was not an ending.
    case running
    /// It finished and answered.
    case completed
    /// It stopped without answering. The API refusing it ten times running is this, and on the
    /// night this was measured it was all three subagents in the capture.
    case failed
    /// Killed rather than finished: by the parent turn ending, by the owner, or by the CLI's own
    /// limits. Kept apart from `failed` because nothing went wrong, and a cross beside a row
    /// nobody's code broke is a lie that costs somebody ten minutes.
    case stopped

    /// Whether nothing further is expected. The roster keeps terminal rows for the rest of the
    /// turn, which is the whole of option 2.
    public var isFinished: Bool { self != .running }
}

/// What can move a subagent's state.
///
/// The evidence travels on the event and not in the state, which is the same argument
/// `SetupEvent` makes at length: a summary and an `output_file` belong to three of the four
/// states, so hanging them off cases would make one combination representable three times over.
public enum SubagentLifecycleEvent: Sendable, Hashable {
    /// `system/task_started` arrived for this subagent.
    case spawned
    /// A status word off `system/task_updated`'s patch or `system/task_notification`, exactly as
    /// the CLI spelled it. Reading it is `SubagentState.init(reported:)`'s job, and a word nobody
    /// recognises is refused rather than guessed at.
    case reported(status: String)
    /// The turn that owned this subagent ended without the CLI saying what became of it. Sent by
    /// the roster when a result line lands, so a row cannot breathe for ever behind a finished
    /// turn: the process that would have told us is gone.
    case turnEnded
}

extension SubagentState {
    /// Read one of the CLI's status words. Nil for a word this does not know, which is refused
    /// upstream rather than folded into the nearest state: a subagent shown as failed because a
    /// later CLI invented `throttled` would be a bug that only ever appears on somebody else's
    /// machine.
    ///
    /// The synonyms are here because two lines report the same ending in two vocabularies:
    /// `task_updated.patch.status` and `task_notification.status`. Only `failed` was in the
    /// capture, so the rest are read generously on purpose.
    public init?(reported status: String) {
        switch status.lowercased() {
        case "running", "in_progress", "in-progress", "started", "pending", "queued":
            self = .running
        case "completed", "complete", "success", "succeeded", "done", "finished":
            self = .completed
        case "failed", "failure", "error", "errored":
            self = .failed
        case "killed", "cancelled", "canceled", "stopped", "aborted", "interrupted", "refused":
            self = .stopped
        default:
            return nil
        }
    }

    /// Where this state goes when the event happens, and nowhere else.
    ///
    /// The refusals, and what each is about:
    ///
    /// **Anything at all from a finished state.** A subagent that has answered does not go back to
    /// work, and `task_id` is stable for the whole turn, so a second `task_started` under an id
    /// that has already ended is the CLI reusing a handle or Bloom replaying a line twice. Both
    /// were possible while this was being built: the roster is fed from a pump that is restarted
    /// when a session is resumed, and a replayed `task_started` would have put a breathing mark
    /// back on a row that had finished minutes ago.
    ///
    /// **A status word nobody knows.** Refused rather than guessed. See `init(reported:)`.
    ///
    /// `spawned` from `running` is `unchanged` rather than refused, and `reported(running)` from
    /// `running` likewise: the CLI sends `task_updated` for things other than an ending, and a
    /// machine that fired on the ordinary case is a machine somebody routes around.
    ///
    /// `turnEnded` is the one event that is legal from `running` and says nothing about it having
    /// worked, which is why it lands on `stopped` rather than on `failed`.
    public func transition(on event: SubagentLifecycleEvent) -> StateTransition<SubagentState> {
        switch event {
        case .spawned:
            guard self == .running else { return .refused }
            return .unchanged

        case .reported(let status):
            guard let reported = SubagentState(reported: status) else { return .refused }
            guard self == .running else {
                // A second line agreeing with the ending already recorded is not an error. Both
                // `task_updated` and `task_notification` report the same ending, in that order,
                // every single time in the capture.
                return self == reported ? .unchanged : .refused
            }
            return reported == .running ? .unchanged : .moves(to: reported)

        case .turnEnded:
            guard self == .running else { return .unchanged }
            return .moves(to: .stopped)
        }
    }
}
