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
    /// Setup is the only one left. Merge was the other, until merging became a turn in the
    /// transcript rather than something Bloom did to a workspace behind its back: an agent
    /// running `gh pr merge` in front of the reader needs no row from Bloom saying it happened.
    enum Kind: String, Equatable {
        case setup
    }

    /// Three endings and a beginning. There was a fourth, `partial`, for a merge that landed on
    /// GitHub and then failed to tidy up afterwards. Nothing here merges any more, so nothing here
    /// can end half way.
    enum Outcome: Equatable {
        case running
        case succeeded
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
    /// The line of `log` that says what failed, when something did. The row marks that line and
    /// its continuations and leaves the rest of the output in the ordinary ink: a script that
    /// created a symlink, restarted nginx and issued a certificate before it stopped is mostly
    /// success, and painting all of it red said the opposite. See `SetupLogLine`.
    var failureSummary: String = ""
    var durationMS: Int?

    /// How many lines `log` holds, counted once when the event is built rather than in a body.
    ///
    /// Two body getters asked for it, `runningTail` and `hasMoreToShow`, so a chat pane resize
    /// paid `LogTail.lineCount` twice per pass per row while the pointer was moving. It scans the
    /// log's UTF-8, which is already the cheap way to count lines, and the cheapest scan is the
    /// one that does not happen: this is a pure function of `log`, and `log` changes only when
    /// the script prints, which is not once per frame.
    ///
    /// Stored rather than computed, and that is what forces the initialiser below: a property
    /// observer does not fire during initialisation, so a memberwise `init` would have left this
    /// at zero, and a computed property is what was already there.
    let logLines: Int

    /// Written out because `logLines` is derived rather than passed. The compiler's memberwise
    /// initialiser would take it as an argument and let a caller state a count that disagrees
    /// with the log beside it.
    init(
        id: String = UUID().uuidString,
        kind: Kind,
        outcome: Outcome,
        title: String,
        detail: String = "",
        note: String = "",
        log: String = "",
        failureSummary: String = "",
        durationMS: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.outcome = outcome
        self.title = title
        self.detail = detail
        self.note = note
        self.log = log
        self.failureSummary = failureSummary
        self.durationMS = durationMS
        self.logLines = LogTail.lineCount(log)
    }

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
        }
    }

    private var tint: ToolTint {
        switch outcome {
        case .running: .accent
        case .succeeded: .positive
        case .failed: .negative
        case .skipped: .neutral
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
    /// - Parameter status: what the script exited with, when this launch watched the run.
    static func setup(
        state: SetupState, log: String, durationMS: Int?, status: Int? = nil
    ) -> WorkspaceEvent? {
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
                // Counted here as well as in the initialiser, and deliberately not shared: this
                // one is a sentence built before the value exists.
                detail: lines == 1 ? "1 line of output" : "\(lines) lines of output",
                log: log, durationMS: durationMS
            )

        case .failed:
            // Read rather than guessed at. `LogTail.lastLine` used to answer this, and the last
            // line of a failed run is the failure only by luck: `psql` prints its error and then
            // an indented question under it, so the row said "Is the server running on that host
            // and accepting TCP/IP connections?" and never showed the line that said what had
            // happened. See `SetupDiagnosis`, which is in the core and tested against that run.
            let diagnosis = SetupDiagnosis.read(log: log, status: status)
            return WorkspaceEvent(
                id: "setup", kind: .setup, outcome: .failed,
                title: diagnosis.title, detail: diagnosis.summary,
                // The generic instruction ends in "run setup again", and so does every remedy
                // that has one, so saying both put "run setup again" in the sentence twice. When
                // the diagnosis knows what to do, the only thing left to add is the half a red
                // row must always carry: whether anything else happened. See `SetupFailure`.
                note: [
                    diagnosis.sentence,
                    diagnosis.advice.isEmpty ? SetupFailure.instruction : SetupFailure.noAgent,
                ]
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
                log: log, failureSummary: diagnosis.summary, durationMS: durationMS
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
}

/// What a workspace whose setup script failed is told, in one place.
///
/// It was written out three times, in three files, in three different shapes: "Run setup again
/// from the Setup tab below" on the transcript row, "Check the Setup tab for the output" on the
/// workspace's own error, "the output is in the Setup tab" in the notification. Three sentences
/// about one event, and a reader who saw two of them had to work out that they were the same.
///
/// It names no tab, and that is the second half of the fix. The Setup tab is only in the bottom
/// panel's strip while the repository has a setup script configured (see `BottomPanelView.tabRow`),
/// so a workspace whose script was removed after a failed run was being sent to a tab that is not
/// there. What is always true is that the output is in the panel below, which is what the row's
/// own log tail and its "Show the full log" link already open onto, and that running setup again
/// is the way out.
enum SetupFailure {
    static let instruction = "No agent was started. Check the setup output and run setup again."

    /// The half of that sentence which is true whatever went wrong, for the rows where
    /// `SetupDiagnosis` already said what to do and saying it twice would be the only result.
    ///
    /// It is the half that must never be dropped. A red row that leaves somebody guessing whether
    /// their worktree survived, or whether an agent is off working in it anyway, is worse than one
    /// that explains nothing.
    static let noAgent = "No agent was started."
}
