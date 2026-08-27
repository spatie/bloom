import Foundation

/// Why the queue in front of a conversation is not moving, and the one sentence that says so.
///
/// A pending message has to be honest about which kind of pending it is. "Waiting for the setup
/// script" and "waiting behind a turn" look identical on screen and are nothing alike to somebody
/// deciding whether to wait or to press Stop, and the app already made the first of those two
/// promises out loud ("It goes as soon as setup finishes") in a place that could not keep it.
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
    case turn
    /// The setup script failed, so no turn was ever started here. The queue is not lost, it is
    /// simply not going anywhere on its own: an agent must not be launched into a worktree whose
    /// dependencies are not installed just because a timer said so.
    case setupFailed
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
    public static func of(
        isRunningSetup: Bool,
        didSetupFail: Bool,
        isTurnRunning: Bool,
        isAwaitingQuestion: Bool
    ) -> DeliveryHold {
        if isRunningSetup { return .setup }
        if isAwaitingQuestion { return .question }
        if isTurnRunning { return .turn }
        if didSetupFail { return .setupFailed }
        return .none
    }

    /// Whether a drain triggered right now may hand the next delivery to the runner.
    public var allowsDelivery: Bool { self == .none }

    /// What the pending bubble says under itself, or nothing when nothing is holding it.
    ///
    /// Only the first one in the queue carries it. A column of four bubbles each explaining that
    /// it is waiting for the same turn says the same thing four times; the ones behind the first
    /// are visibly behind it, which is the whole of what they have to say.
    ///
    /// **Nothing holding it says nothing.** It said "Goes with your next message", which is the
    /// ordinary way a queued message behaves and the only thing it could have been waiting for;
    /// the four sentences above are worth reading because each names a specific thing to wait on,
    /// and a fifth explaining that there is nothing to wait on made the other four look like
    /// decoration. `setupFailed` still says it, because there the reader is being told why
    /// something did NOT go.
    public var sentence: String? {
        switch self {
        case .setup: "Goes as soon as setup finishes."
        case .question: "Goes once you have answered the question above."
        case .turn: "Goes when this turn ends."
        case .setupFailed: "Setup failed, so this has not gone. It goes with your next message."
        case .none: nil
        }
    }
}
