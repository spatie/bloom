import Foundation

/// What a runner does when the store refuses one of its writes, and the count it keeps of it.
///
/// **Both runners held this, and the bodies were the same to the line.** `AgentRunner.report` and
/// `CodexRunner.report` each diagnosed the refusal through `WorkspaceTrouble.recording`, each
/// bumped a `persistenceFailures`, each set a `lastFailure`, each yielded the sentence to their own
/// sink, and each carried a `transcriptWentAway` flag with a `guard` in front of the stop it
/// guards. The Codex copy's own doc comment points at the Claude Code one for the argument rather
/// than restating it, which is the honest thing to do with duplication and is also the sign that it
/// should not have been duplication.
///
/// What could not move with it is the last line of each: this backend stops by killing a process
/// it will spawn again, that one stops by killing a long lived server, and `SessionRunner`'s head
/// is right that the two are not one act. So the decision moves here and the verb stays at the
/// call site.
///
/// # The decision itself
///
/// Two refusals that look identical to SQLite, which says "FOREIGN KEY constraint failed" for
/// both, and must not be treated alike:
///
///   * **The database has gone wrong.** These used to be `try?` and the event went out as though
///     it had been stored, so a failing database threw a whole transcript away and told nobody.
///     The sentence reaches the window as an `.error` and stays readable on the runner afterwards.
///   * **The transcript has gone.** Archiving or removing a workspace under a turn that is still in
///     flight deletes the session row, `ON DELETE CASCADE`, and the foreign key on
///     `messages.session_id` then correctly refuses the next row the turn writes. Nothing is wrong
///     there: the owner's own gesture removed the transcript, so there is nowhere for the write to
///     go and nothing worth saying about it. What is a fault is an agent still working in a
///     worktree nobody is recording, so the run is stopped, silently.
///
/// The second is answered **once**. Everything already in flight when the rows went will be refused
/// the same way on its way through: the turn's remaining lines, the session save that stopping
/// provokes, and any question still open. One stop covers all of them, and a second would arrive
/// while the first was still being carried out.
///
/// A value type rather than a class, because each runner holds one inside its own actor and there
/// is nothing to share between them: what is shared is the rule, which is this file.
struct PersistenceTrouble: Sendable, Equatable {
    /// How many writes have been refused for a reason worth telling somebody about. Read by the
    /// suite, which is the only thing that asks.
    private(set) var failures = 0

    /// The last sentence a person was shown, or nil when none has been.
    private(set) var lastSentence: String?

    /// Whether this run has already been stopped because its transcript was deleted underneath it.
    private(set) var hasStopped = false

    /// What the caller is to do about a refusal.
    enum Outcome: Sendable, Equatable {
        /// Say this on the event stream. The count and the sentence are already recorded.
        case tell(String)
        /// The transcript has gone. Stop the run, and say nothing at all.
        case stop
        /// The transcript went a moment ago and the run is already being stopped. Do nothing.
        case alreadyStopped
    }

    /// - Parameter trouble: what `WorkspaceTrouble.recording` made of the refusal, which is nil
    ///   exactly when the session row is no longer there.
    mutating func record(_ trouble: WorkspaceTrouble?) -> Outcome {
        guard let trouble else {
            guard !hasStopped else { return .alreadyStopped }
            hasStopped = true
            return .stop
        }
        failures += 1
        lastSentence = trouble.sentence
        return .tell(trouble.sentence)
    }
}
