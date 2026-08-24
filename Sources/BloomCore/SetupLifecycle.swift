import Foundation

/// Everything that can move a workspace's `setupState`, and the columns that have to move with it.
///
/// **Why the events carry their evidence and the states do not.** `setupState` sits next to
/// `setupLog`, and until this file existed `.failed` with an empty log was as type-correct as
/// `.failed` with the stderr that caused it. The obvious fix is to put the log inside the case,
/// `.failed(log: String)`, and it is the wrong one: the log is not the property of one case. A run
/// in flight is accumulating one, a run recovered at launch has a line explaining why it stopped,
/// and a restored worktree has a line explaining what is missing. Hanging the same `String` off
/// four of five cases is not making a bad combination unrepresentable, it is making the same
/// combination representable four times over, and it costs `RawRepresentable`, which is what
/// `setup_state` is stored as and what `recoverInterruptedSetups` compares against in SQL.
///
/// So the evidence is on the **event**, where it belongs. An event is a thing that happened and it
/// always knows what happened, `runFinished` cannot be spelled without its log, and nothing here is
/// ever persisted so none of it costs a column. The state stays a bare summary, which is what a
/// summary is.
///
/// **Where recovery fits.** `worktreeRebuilt` and `runInterrupted` are in this table, not around
/// it. Two of the writes that move this state are the app telling the truth about something that
/// happened while it was not looking: a setup script is a child of this process, so a row still
/// `running` at launch is a run that was killed, and archiving removes the whole worktree, so a
/// restored one is a fresh checkout wearing an old workspace's row. Neither is an illegal
/// transition and neither may be refused, so each is a case with its own row rather than an
/// exception somebody remembers to make. `worktreeRebuilt` in particular is legal from **every**
/// state, including `running`, because it is a fact about a directory and a fact does not ask
/// permission.
public enum SetupEvent: Sendable, Hashable {
    /// The setup script was launched in this worktree.
    case runStarted
    /// It exited, and this is what it printed. The log is not optional and there is no event that
    /// reports an outcome without one, which is the half-written failure this design exists to
    /// stop: `.failed` with nothing to read is a state the next reader treats as whole.
    case runFinished(succeeded: Bool, log: String)
    /// There was nothing to run: no setup script in the settings file, or a settings file naming a
    /// script that is not there. The note is that second case, and it is what the workspace's setup
    /// log says instead of the output it never got.
    case runSkipped(note: String?)
    /// The app died while the run was going. Sent only by the launch pass, which finds the rows by
    /// their state. See `Store.recoverInterruptedSetups`.
    case runInterrupted
    /// The worktree was cut again from the branch, so anything the setup script installed is gone.
    /// Sent by restore. See `WorkspaceManager.restore`.
    case worktreeRebuilt(hasSetupScript: Bool)

    /// The line this event leaves in the setup log, when the event is the only account of itself.
    ///
    /// Held here rather than at the call site because `recoverInterruptedSetups` writes it in SQL
    /// and `apply` writes it in Swift, and two copies of a sentence are two sentences waiting to
    /// disagree about what happened.
    public var note: String? {
        switch self {
        case .runStarted:
            nil
        case .runFinished:
            nil
        case .runSkipped(let note):
            note
        case .runInterrupted:
            "[bloom] The app stopped while the setup script was running, so this run was "
                + "interrupted before it could report a result. Run setup again to finish it."
        case .worktreeRebuilt:
            "[bloom] This worktree was rebuilt when the workspace was restored, so anything the "
                + "setup script installed is gone. Run setup again."
        }
    }

    /// Whether the note replaces the log or is added to the end of it.
    ///
    /// A skipped run replaces, because "the settings file names a script that is not there" is the
    /// whole account of the run and whatever the last one printed is about a different worktree or
    /// a different script. Recovery adds, because what is already there is the output of the run
    /// being explained, and the explanation is worthless without it.
    var noteReplacesLog: Bool {
        if case .runSkipped = self { return true }
        return false
    }
}

public extension SetupState {
    /// Where this state goes when the event happens, and nowhere else.
    ///
    /// The refusals, and the bug behind each:
    ///
    /// **`runFinished` from anything but `running`.** A result belongs to the run the row is
    /// tracking, and if the row is not tracking one then the result is from a run that has been
    /// superseded. Pressing "Run setup again" cancels the task in flight and starts another, and
    /// the cancelled one still gets to reach its completion handler; without this, the old run's
    /// `succeeded` landed on top of the new run's `running` and the sidebar said a workspace was
    /// ready while its `composer install` was still going. The same shape as the restore bug, one
    /// event later: an outcome that is true about a run nobody is waiting for any more.
    ///
    /// **`runInterrupted` from anything but `running`.** There is nothing to interrupt, and
    /// `pending` is where an interrupted run is filed, so accepting it would let the launch pass
    /// annotate rows it has nothing to say about, once per launch, for ever.
    ///
    /// **`runSkipped` from `running`.** The three checks that decide there is nothing to run all
    /// happen before the script is launched. Reaching this from `running` means a live process is
    /// being filed as a run that never happened.
    ///
    /// `runStarted` from `running` is `unchanged` rather than refused on purpose. Two runs at once
    /// is guarded where the runs are, by `WorkspaceModel.canRunSetup`, and the column already says
    /// the true thing. A machine that refused here would fire on the ordinary re-run race, and a
    /// rule that fires on correct code is a rule people learn to route around.
    func transition(on event: SetupEvent) -> StateTransition<SetupState> {
        switch event {
        case .runStarted:
            return self == .running ? .unchanged : .moves(to: .running)

        case .runFinished(let succeeded, _):
            guard self == .running else { return .refused }
            return .moves(to: succeeded ? .succeeded : .failed)

        case .runSkipped:
            if self == .running { return .refused }
            return self == .skipped ? .unchanged : .moves(to: .skipped)

        case .runInterrupted:
            guard self == .running else { return .refused }
            return .moves(to: .pending)

        // Never refused, from any state. The worktree is a fresh checkout whatever the row was
        // saying a moment ago, and the row does not get a vote on what is on disk.
        case .worktreeRebuilt(let hasSetupScript):
            let destination: SetupState = hasSetupScript ? .pending : .skipped
            return self == destination ? .unchanged : .moves(to: destination)
        }
    }
}

public extension Workspace {
    /// Move the setup state, and write everything that goes with it. The only way in.
    ///
    /// `setupState` is `public internal(set)`, so nothing in `Sources/Bloom` can assign it at all
    /// and this is the whole of the door. Inside the core the compiler cannot help, which is what
    /// the house rule covers.
    ///
    /// The point is not that the transition is legal. It is that a state and the work that goes
    /// with it are one thing: writing `failed` into `setupState` on its own is a half-truth, and the next
    /// reader treats a half-truth as whole. Here the log lands in the same statement as the state,
    /// so a run cannot be filed without its output and a recovery cannot be filed without its
    /// explanation.
    ///
    /// Mutating a value, not writing a row. Call it inside `Store.update(workspaceID:)`, which
    /// reads and writes with no suspension in between, so a setup run that takes ten minutes
    /// cannot roll back the rename that happened during it.
    @discardableResult
    mutating func apply(_ event: SetupEvent) -> StateTransition<SetupState> {
        let outcome = setupState.transition(on: event)

        switch outcome {
        case .refused:
            RefusedTransitions.record(
                machine: "setup", from: setupState.rawValue, event: event.name
            )
            return outcome

        case .unchanged:
            return outcome

        case .moves(let next):
            setupState = next
        }

        if case .runFinished(_, let log) = event {
            setupLog = Self.capped(log)
        } else if let note = event.note {
            setupLog = event.noteReplacesLog || setupLog.isEmpty
                ? note
                : Self.capped(setupLog + "\n" + note)
        }

        return outcome
    }

    /// The tail of a long log, because the whole of one is not worth a row.
    ///
    /// Here rather than at the call site so nothing can write an uncapped one. A `swift build` in a
    /// cold worktree prints tens of megabytes and none of it is worth carrying in every read of the
    /// workspaces table.
    private static func capped(_ log: String) -> String {
        log.count > setupLogLimit ? String(log.suffix(setupLogLimit)) : log
    }

    /// The cap on the setup log, wherever it is held.
    ///
    /// Two copies of this number, one here and one on the app's `WorkspaceModel`, with a comment
    /// on each saying it matched the other. They cap the same log: this one as it is written to
    /// the row, the other as it is held in memory during the run and re-rendered on every append.
    /// A `swift build` in a cold worktree prints tens of megabytes and none of it is worth
    /// carrying in either place.
    static let setupLogLimit = 200_000
}

extension SetupEvent {
    /// What a refusal calls this event. The case name, so the log line and the source agree.
    var name: String {
        switch self {
        case .runStarted: "runStarted"
        case .runFinished(let succeeded, _): succeeded ? "runFinished(succeeded)" : "runFinished(failed)"
        case .runSkipped: "runSkipped"
        case .runInterrupted: "runInterrupted"
        case .worktreeRebuilt(let hasSetupScript): "worktreeRebuilt(hasSetupScript: \(hasSetupScript))"
        }
    }
}
