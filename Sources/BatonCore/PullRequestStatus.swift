import Foundation

/// How a pull request should present itself: what the strip says, what colour it carries, and
/// whether the merge button is allowed to do anything.
///
/// The tone is a meaning, not a colour. The view resolves it against the palette, so the same
/// decision drives the inspector strip and anything else that ever shows this state, and so the
/// decision itself can be tested without a window.
public struct PullRequestStatus: Sendable, Hashable {
    public enum Tone: String, Sendable, Hashable, CaseIterable {
        /// Nothing to signal. Drawn as no tint at all rather than as a grey wash.
        case neutral
        case positive
        case negative
        case warning
        /// Done, rather than good: the accent colour, the way the app marks a finished thing.
        case accent
    }

    public var tone: Tone
    /// One line. The strip truncates it, so the most specific words come first.
    public var text: String
    public var canMerge: Bool
    /// Why not, in a sentence a tooltip can show. Nil when merging is allowed.
    public var blockedReason: String?

    public init(tone: Tone, text: String, canMerge: Bool, blockedReason: String? = nil) {
        self.tone = tone
        self.text = text
        self.canMerge = canMerge
        self.blockedReason = blockedReason
    }
}

public extension PullRequest {
    var isOpen: Bool { state.caseInsensitiveCompare("OPEN") == .orderedSame }
    var isMerged: Bool { state.caseInsensitiveCompare("MERGED") == .orderedSame }
    var isClosed: Bool { state.caseInsensitiveCompare("CLOSED") == .orderedSame }

    /// GitHub reports this through two fields with different vocabularies, and gh hands back
    /// whichever one the installed version knows about. `DIRTY` is `mergeStateStatus` for the
    /// same thing `mergeable` calls `CONFLICTING`.
    var hasConflicts: Bool {
        guard let mergeable = mergeable?.uppercased() else { return false }
        return mergeable == "CONFLICTING" || mergeable == "DIRTY"
    }

    /// Present tense, because it is the label on a button that has not been pressed yet.
    var reviewLabel: String? {
        guard let reviewDecision, !reviewDecision.isEmpty else { return nil }
        return reviewDecision.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var status: PullRequestStatus {
        if isMerged {
            return PullRequestStatus(
                tone: .accent,
                text: "Merged",
                canMerge: false,
                blockedReason: "This pull request is already merged."
            )
        }
        if isClosed {
            return PullRequestStatus(
                tone: .neutral,
                text: "Closed",
                canMerge: false,
                blockedReason: "This pull request was closed without merging."
            )
        }
        // Conflicts outrank the check rollup: green checks on a branch that cannot be applied to
        // the base is the one combination where the cheerful answer is the wrong one.
        if hasConflicts {
            return PullRequestStatus(
                tone: .negative,
                text: "Conflicts with the base branch",
                canMerge: false,
                blockedReason: "Resolve the conflicts with the base branch first."
            )
        }
        if isDraft {
            return PullRequestStatus(
                tone: .neutral,
                text: checksText,
                canMerge: false,
                blockedReason: "This pull request is still a draft."
            )
        }

        return PullRequestStatus(tone: openTone, text: checksText, canMerge: true)
    }

    /// The title of the confirmation, which is the one line a user reliably reads.
    func mergeConfirmationTitle(base: String) -> String {
        "Merge #\(number) into \(base)?"
    }

    /// What merging does, said as a list of consequences rather than as a question.
    ///
    /// Merging is not undoable from here: gh has no reverse for it, and the branch is gone from
    /// GitHub afterwards. So the dialog names the pull request, the branch and the base by name,
    /// and repeats a red check rather than letting the button hide it.
    func mergeConfirmation(method: GitHub.MergeMethod, base: String, deletesBranch: Bool) -> String {
        var text = "\(method.label) puts #\(number) \"\(title)\" into \(base) on GitHub."
        // An older gh does not report the head branch, and naming a branch we are guessing at
        // would be worse than not naming one.
        if deletesBranch, !branch.isEmpty {
            text += "\n\nThe branch \(branch) is deleted on GitHub. The worktree on this machine "
                + "is left alone."
        }
        if checks == .failing || hasConflicts {
            text += "\n\n\(checks == .failing ? checksSummary : "This branch conflicts with \(base).")"
        }
        text += "\n\nBaton cannot undo this."
        return text
    }

    /// The check rollup if gh gave us one, the review state if it did not, and the plain fact
    /// that a pull request exists if neither is known.
    private var checksText: String {
        if !checksSummary.isEmpty, checks != .none { return checksSummary }
        if let reviewLabel { return reviewLabel }
        return checksSummary.isEmpty ? "Open" : checksSummary
    }

    private var openTone: PullRequestStatus.Tone {
        switch checks {
        case .failing: .negative
        case .pending: .warning
        case .passing: reviewDecision?.uppercased() == "CHANGES_REQUESTED" ? .warning : .positive
        case .none: reviewDecision?.uppercased() == "CHANGES_REQUESTED" ? .warning : .neutral
        }
    }
}

public extension GitHub.MergeMethod {
    /// GitHub's own words for the three buttons, so the confirmation reads like the web UI the
    /// user will check afterwards.
    var label: String {
        switch self {
        case .merge: "Merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }
}
