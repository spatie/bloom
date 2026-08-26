import Foundation

/// What to ask before a workspace's setup script is run, in the words the dialog uses.
///
/// It is asked at all because the run is not cheap and is not Bloom's to undo. The script is
/// whatever the project's settings file names, it is launched with the worktree as its working
/// directory, and the two things it is written to do are install dependencies and write files.
/// `WorkspaceManager.runSetup` streams its output for as long as it takes, which for a cold
/// checkout is minutes, and `Workspace.setupLogLimit` exists because one of them printed tens of
/// megabytes.
///
/// Here rather than at any of the three controls that offer the run, for the reason `SetupRunOffer`
/// is here: there are three of them, and three copies of a sentence are three sentences waiting to
/// disagree.
public enum SetupRunConfirmation {
    /// One confirmation's worth of words. The app owns the dialog; these are the sentences in it.
    public struct Question: Equatable, Sendable {
        public var title: String
        public var message: String
        public var confirmLabel: String
        public var cancelLabel: String

        public init(title: String, message: String, confirmLabel: String, cancelLabel: String) {
            self.title = title
            self.message = message
            self.confirmLabel = confirmLabel
            self.cancelLabel = cancelLabel
        }
    }

    /// What to ask before running setup in a workspace.
    ///
    /// **One question with a conditional line, rather than two questions.** The action, its cost
    /// and its confirm button are the same whether or not an agent is working: a turn in flight
    /// adds a fact to weigh, not a different decision to take. Two questions would mean two titles
    /// and two confirm labels for one menu item, which is the drift `SetupRunOffer` was written to
    /// stop one layer up.
    ///
    /// **What the agent line says is that nothing stops.** Setup is a child process of this app
    /// and the agent is another, so the script does not interrupt the turn, and the reader's
    /// worry is the opposite one: two writers in one worktree. Warning that the agent would be
    /// cancelled would be warning about something that does not happen.
    ///
    /// The title follows the item that was pressed, which says "again" only when there was a first
    /// time. See `WorkspaceModel.hasRunSetup`.
    public static func question(hasRunSetup: Bool, isAgentRunning: Bool) -> Question {
        var message = "This project\u{2019}s setup script runs in the worktree. It can take "
            + "minutes, and Bloom cannot undo what it writes."

        if isAgentRunning {
            message += "\n\nAn agent is mid turn here. The script does not stop it, so both "
                + "write to this worktree at once."
        }

        return Question(
            title: hasRunSetup ? "Run the setup script again?" : "Run the setup script?",
            message: message,
            confirmLabel: hasRunSetup ? "Run Setup Again" : "Run Setup",
            cancelLabel: "Don\u{2019}t Run"
        )
    }
}
