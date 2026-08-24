import Foundation

/// Whether a worktree is finished being built, said in the one sentence a terminal opened in it
/// has to carry.
///
/// The chat has had this for as long as there has been a queue: a pending bubble under a workspace
/// whose setup script is still going says "Goes as soon as setup finishes", and the rule behind it
/// is `DeliveryHold`. A terminal had nothing. A workspace created to be worked in by hand opens
/// its shell the moment the worktree exists, which is several minutes before `bun install` has
/// finished, and the prompt looks exactly as it does when everything is installed. The one thing
/// that made the difference visible was reading the transcript, which is the tab such a workspace
/// was created in order not to use.
///
/// Here rather than in the pane for the reason `DeliveryHold` is here: the precedence is a
/// decision, the sentences are a promise the app makes out loud, and the test target cannot see a
/// view.
public enum WorktreeReadiness: Equatable, Sendable, CaseIterable {
    /// The setup script is running right now. The shell works, and half of what it needs is not
    /// there yet.
    case installing
    /// The setup script ran and failed. Nothing is going to install the dependencies on its own,
    /// so a command that cannot find them is the expected outcome rather than a surprise.
    case failed
    /// Nothing to say: either setup finished, or this project has no script to run.
    case ready

    /// `isRunningSetup` beats the stored state, because a re-run is under way while the row still
    /// carries the verdict of the run before it. A terminal that said "setup failed" over a script
    /// that was at that moment succeeding is the one wrong answer this ordering rules out.
    public static func of(isRunningSetup: Bool, setupState: SetupState) -> WorktreeReadiness {
        if isRunningSetup { return .installing }
        switch setupState {
        case .running: return .installing
        case .failed: return .failed
        case .pending, .succeeded, .skipped: return .ready
        }
    }

    /// What the strip above the shell says, or nothing when there is no strip.
    ///
    /// Both sentences name the worktree rather than the app, because what somebody is about to do
    /// in this shell is run something in this directory, and "installing" on its own reads as the
    /// app being busy rather than as the directory being incomplete.
    public var sentence: String? {
        switch self {
        case .installing: "Setting this worktree up. Its dependencies are still installing."
        case .failed: "Setup failed in this worktree, so its dependencies may be missing."
        case .ready: nil
        }
    }

    /// Whether the worktree is finished, whatever the verdict. Read by anything that wants to know
    /// there is nothing left to wait for, as opposed to nothing left to say.
    public var isSettled: Bool { self != .installing }
}
