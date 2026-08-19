import SwiftUI
import BloomCore

/// Something Bloom itself did to a workspace, as the transcript shows it.
///
/// The transcript used to be a record of one conversation. It is the surface a user watches while
/// a workspace is working, though, and plenty happens to a workspace that nobody said: a setup
/// script runs for a minute before the first prompt can go, a pull request is merged, a branch is
/// renamed, a check fails. None of that appeared anywhere near the conversation, so the answer to
/// "what happened to this workspace" was spread across a tab at the bottom, a strip in the
/// inspector and a notification that has already gone.
///
/// One value for all of it, rather than a bespoke row per thing Bloom does. Setup and merge are
/// the first two and the shape is deliberately general: a kind, an outcome, a line, an optional
/// sentence and an optional log.
///
/// **None of this is a message, and that is the safety property that matters.** Everything else in
/// the transcript comes out of the `messages` table, which is what `ContextWindowUsage` counts and
/// what the turn scanners read. A `WorkspaceEvent` is never written to that table, never appended
/// to `TranscriptModel.rows`, and never seen by anything that assembles a prompt: what an agent
/// receives is the text the user typed plus its own resumed session. It lives here, in the
/// transcript's own directory, rather than in `BloomCore` next to the stored model, because being
/// presentation and nothing else is the whole of its contract.
struct WorkspaceEvent: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case setup
        case merge
    }

    /// Three endings and a beginning. `partial` is not a nicety: `gh pr merge --delete-branch`
    /// merges on GitHub and can still fail to delete the local branch, because a worktree cannot
    /// check out a base branch that the main checkout has. Saying only "merged" would hide the
    /// half that needs the user, and saying "failed" would be a lie about the half that worked.
    enum Outcome: Equatable {
        case running
        case succeeded
        case partial
        case failed
        /// Nothing ran, and why is worth a line: a settings file naming a script that is not there.
        case skipped
    }

    var id = UUID().uuidString
    var kind: Kind
    var outcome: Outcome
    /// The row's label. Short, and in the past tense once it has happened.
    var title: String
    /// One line beside the label. The last line of a running log, a count, a branch name.
    var detail: String = ""
    /// A sentence under the row, for the cases where the reader has to do something next.
    var note: String = ""
    /// Output worth showing, if there is any. Only setup has this today.
    var log: String = ""
    var durationMS: Int?

    var isRunning: Bool { outcome == .running }
    var isFailure: Bool { outcome == .failed }

    // MARK: - How it is drawn

    /// The same vocabulary a tool row uses, so an event lines up on the transcript's columns
    /// instead of being a second design for a row.
    var presentation: ToolPresentation {
        ToolPresentation(glyph: glyph, label: title, detail: detail, tint: tint)
    }

    private var glyph: String {
        switch (kind, outcome) {
        case (.setup, .running): "gearshape.2"
        case (.setup, .succeeded): "checkmark.seal"
        case (.setup, .skipped): "gearshape.2"
        case (.setup, _): "exclamationmark.triangle"
        case (.merge, .running): "arrow.triangle.merge"
        case (.merge, .succeeded): "checkmark.seal"
        case (.merge, .partial): "exclamationmark.circle"
        case (.merge, _): "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch outcome {
        case .running: Palette.accent
        case .succeeded: Palette.positive
        case .partial: Palette.warning
        case .failed: Palette.negative
        case .skipped: Palette.textSecondary
        }
    }

    // MARK: - Setup

    /// The setup event, built from the workspace's own state rather than recorded as it happens.
    ///
    /// Setup is the one kind whose state is already durable: `setupState` and `setupLog` are
    /// columns on the workspace row, written by `WorkspaceManager` as the script runs. Deriving
    /// the event from them means a workspace reopened next week still says how its setup ended,
    /// with the log a disclosure away, and that nothing has to be kept in step by hand. It also
    /// means a re-run replaces the line rather than appending a second one, which is right: a
    /// workspace has one setup, however many times it has been run.
    static func setup(state: SetupState, log: String, durationMS: Int?) -> WorkspaceEvent? {
        switch state {
        case .pending:
            // It has not started. A line saying so would appear in every workspace whose repo has
            // no setup script at all.
            return nil

        case .running:
            return WorkspaceEvent(
                id: "setup", kind: .setup, outcome: .running,
                title: "Setting up", detail: LogTail.lastLine(log), log: log
            )

        case .succeeded:
            guard !log.isEmpty else { return nil }
            let lines = LogTail.lineCount(log)
            return WorkspaceEvent(
                id: "setup", kind: .setup, outcome: .succeeded,
                title: "Setup finished",
                detail: lines == 1 ? "1 line of output" : "\(lines) lines of output",
                log: log, durationMS: durationMS
            )

        case .failed:
            return WorkspaceEvent(
                id: "setup", kind: .setup, outcome: .failed,
                title: "Setup failed", detail: LogTail.lastLine(log),
                note: "The agent was not started. Run setup again from the Setup tab below.",
                log: log, durationMS: durationMS
            )

        case .skipped:
            // Two different skips. One is a repository with no setup script, which is silent and
            // is the common case. The other is a settings file naming a script file that is not on
            // disk, and `WorkspaceManager` writes its own sentence about that into the log, which
            // says it better than anything invented here.
            guard !log.isEmpty else { return nil }
            return WorkspaceEvent(
                id: "setup", kind: .setup, outcome: .skipped,
                title: "Setup skipped", detail: LogTail.lastLine(log)
            )
        }
    }

    // MARK: - Merge

    /// A pull request that went in.
    ///
    /// Takes `MergeOutcome` whole rather than a boolean, because the interesting case is the one
    /// with something left over: `gh pr merge --delete-branch` merges on GitHub and can still fail
    /// to tidy up locally, since a worktree cannot check out a branch the main copy already has.
    /// That is neither a success to report plainly nor a failure, and `Leftover.sentence` is
    /// already the right words for it, so the row borrows them instead of writing a second set
    /// that would drift from the ones the inspector shows.
    static func merged(pullRequest: Int, outcome: MergeOutcome) -> WorkspaceEvent {
        WorkspaceEvent(
            kind: .merge,
            outcome: outcome.leftover == nil ? .succeeded : .partial,
            title: "Merged #\(pullRequest)",
            detail: outcome.leftover == nil ? "" : "Something was left over",
            note: outcome.leftover?.sentence ?? ""
        )
    }

    /// A merge that did not happen. The reason is whatever GitHub said, which is more useful than
    /// any wording chosen in advance.
    static func mergeFailed(pullRequest: Int, reason: String) -> WorkspaceEvent {
        WorkspaceEvent(
            kind: .merge,
            outcome: .failed,
            title: "Merge failed",
            detail: "#\(pullRequest)",
            note: reason
        )
    }
}
