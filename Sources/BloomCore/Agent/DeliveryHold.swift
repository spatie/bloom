import Foundation

/// Why the queue in front of a conversation is not moving, and the one sentence that says so.
///
/// A pending message has to be honest about which kind of pending it is. "Waiting for the setup
/// script" and "waiting behind a turn" look identical on screen and are nothing alike to somebody
/// deciding whether to wait or to press Stop, and the app already made the first of those two
/// promises out loud ("It goes as soon as setup finishes") in a place that could not keep it.
///
/// **A setup script that FAILED holds nothing, and that is the second promise this type had to
/// stop breaking.** There used to be a `setupFailed` case. It refused every delivery, while the
/// bubble under the message read "Setup failed, so this has not gone. It goes with your next
/// message", and the next message did not move it either: the hold is read again on the next
/// drain, a failed `setup_state` does not change by being typed at, and so the queue sat there
/// until somebody ran setup again and it happened to succeed. The rule behind it was that an
/// agent must not be launched into a worktree whose dependencies are not installed. That is the
/// owner's call rather than Bloom's, and the owner's answer is no: a script fails for reasons
/// that have nothing to do with the task (`createdb` not on the PATH the script ran with, valet
/// declining to ask for a password), and a workspace that answers nothing at all is worse than
/// one whose agent is told what went wrong and can install the missing thing itself. The failure
/// is still said in four other places, none of which this changes: the red setup row with its
/// log, the alert, the notification, and `WorkspaceStatus.setupFailed` in the sidebar.
///
/// **A hold and a refusal are two different things, and this type now holds both.** `of` says what
/// the session is doing; `allowsDelivery(on:)` says whether that stops a delivery, and it needs the
/// backend to answer, because a running turn stops one on a CLI that will not read a line written
/// into it and stops nothing on the two that will. Keeping the case and the refusal apart is what
/// lets `WorkspaceMergeTool` go on refusing to merge a worktree an agent is writing into while the
/// composer goes on talking to it.
///
/// Here rather than in the view for the usual reason: the precedence between these is a decision,
/// the drain reads the same answer the bubble does, and the test target cannot see a view. The
/// sentences are here too, so the promise the transcript makes is pinned by the suite rather than
/// retyped slightly differently the next time somebody edits a caption.
public enum DeliveryHold: Equatable, Sendable, CaseIterable {
    /// The worktree's setup script is still running. Nothing may be said to an agent in a
    /// worktree that has not finished being built.
    case setup
    /// The agent has stopped on a permission question. Writing a user line into a turn that is
    /// blocked on an answer is the mid-turn injection every backend is unhappy about.
    case question
    /// The agent is mid turn.
    ///
    /// **Whether that holds anything is the backend's answer, not this case's.** See
    /// `allowsDelivery(on:)`: Claude Code and Codex both take a message into a turn that is
    /// already running, so on those two this names a fact about the session and holds nothing.
    case turn
    /// Nothing in the session is holding it.
    ///
    /// That is not the same as "it is about to go". The queue moves on an event (setup finishing,
    /// a turn ending, the owner submitting) and never on a clock or on launch, because a message
    /// queued yesterday must not start a paid turn on a Mac nobody is sitting at. So a delivery
    /// left over from the last launch, or one behind a turn the owner stopped by hand, sits here
    /// until the owner says something, which is what the sentence tells them.
    case none

    /// The precedence, and it is the whole of the type's logic.
    ///
    /// A question is asked before the turn is checked because a turn that has stopped on one is
    /// still marked running: `TranscriptModel` only clears that flag on a result. Answering
    /// `.turn` there would be true and useless, since what the reader has to do is answer the
    /// question above the composer.
    ///
    /// **It still answers `.turn` for a backend that would take the message anyway, and that is
    /// deliberate.** A hold describes the session; whether it stops a delivery is
    /// `allowsDelivery(on:)`, and the two are kept apart because they have different readers.
    /// `WorkspaceMergeTool` asks for the case, and a running turn is a refusal there whatever the
    /// backend does with a sentence: merging a worktree an agent is writing into is unsafe for
    /// reasons that have nothing to do with whether it can hear you. Collapsing `.turn` into
    /// `.none` for Claude Code would have told that tool a busy workspace was quiet.
    public static func of(
        isRunningSetup: Bool,
        isTurnRunning: Bool,
        isAwaitingQuestion: Bool
    ) -> DeliveryHold {
        if isRunningSetup { return .setup }
        if isAwaitingQuestion { return .question }
        if isTurnRunning { return .turn }
        return .none
    }

    /// Whether a drain triggered right now may hand the next delivery to the runner.
    ///
    /// **The backend is asked because only the backend knows.** `.turn` refused on every one of
    /// them, so a message typed during a turn waited for a turn that would have accepted it. It
    /// now refuses only where writing into a live turn is not a thing the CLI does: see
    /// `AgentKind.acceptsMidTurnMessage`, which carries the measurement for each of the four.
    ///
    /// `.setup` and `.question` refuse everywhere and are not asked. A worktree that is still
    /// being built has nothing installed to work with, and a turn blocked on a permission answer
    /// is not reading anything else, which `SessionLifecycle` says a second time by refusing
    /// `turnStarted` from `waiting`. Neither is a fact about a protocol.
    public func allowsDelivery(on agent: AgentKind) -> Bool {
        switch self {
        case .none: true
        case .turn: agent.acceptsMidTurnMessage
        case .setup, .question: false
        }
    }

    /// What the pending bubble says under itself, or nothing when nothing is holding it.
    ///
    /// Only the first one in the queue carries it. A column of four bubbles each explaining that
    /// it is waiting for the same turn says the same thing four times; the ones behind the first
    /// are visibly behind it, which is the whole of what they have to say.
    ///
    /// **Nothing holding it says nothing.** It said "Goes with your next message", which is the
    /// ordinary way a queued message behaves and the only thing it could have been waiting for;
    /// the three sentences above are worth reading because each names a specific thing to wait on,
    /// and a fourth explaining that there is nothing to wait on made the other three look like
    /// decoration.
    ///
    /// **A running turn says nothing on a backend that would take the message anyway.** "Goes
    /// when this turn ends" is a promise the drain no longer keeps there: on Claude Code and
    /// Codex the queue empties into the turn rather than behind it, so the caption would be
    /// describing a wait that is not happening. Nothing is holding it, so it says what nothing
    /// holding it has always said, which is nothing. See `Delivery.deliverable(from:hold:on:)`.
    public func sentence(on agent: AgentKind) -> String? {
        guard !allowsDelivery(on: agent) else { return nil }
        switch self {
        case .setup: return "Goes as soon as setup finishes."
        case .question: return "Goes once you have answered the question above."
        case .turn: return "Goes when this turn ends."
        case .none: return nil
        }
    }
}
