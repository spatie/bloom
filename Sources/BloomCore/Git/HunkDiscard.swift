import Foundation

/// Throwing away one hunk of a file and leaving the rest of it alone: when that is on offer,
/// where the reverse patch has to land, and what to say when it cannot.
///
/// The command is `Git.discardHunk`. What is here is every decision in front of it, so that the
/// view drawing the control and the git call carrying it out cannot come to two answers.
public enum HunkDiscard {
    /// Whether a hunk control is drawn, and whether it can be pressed.
    public enum Availability: Equatable, Sendable {
        /// Not drawn at all, because this diff has no hunk that could honestly be discarded alone.
        case hidden
        case enabled
        /// Drawn and disabled, with the sentence that says why.
        case disabled(String)
    }

    /// Where the reverse patch is applied, and which of those it must apply to.
    public struct Targets: Equatable, Sendable {
        public var worktree: Requirement
        public var index: Requirement

        public enum Requirement: Equatable, Sendable {
            /// Left alone.
            case untouched
            /// Applied, and the discard is refused when it does not apply here.
            case required
            /// Applied when it applies, and left alone otherwise.
            case whenPresent
        }
    }

    /// The reason every destructive control in a diff gives while an agent is working.
    public static let agentIsWorking =
        "The agent is working in this workspace. Wait for its turn to finish before discarding."

    /// The same, for a hunk while the diff is folded to ignore whitespace.
    public static let whitespaceIsHidden =
        "Turn off Ignore whitespace to discard a single hunk. The hunks shown are not the ones on disk."

    /// Whether the hunks of `file`, in `scope`, get a discard control.
    ///
    /// **Hidden for a file that is all one change.** An added, untracked or deleted file's diff is
    /// one hunk covering the whole file, and reversing it creates or deletes the file: that is the
    /// file's own Discard, which says so in its confirmation and sends an untracked file to the
    /// Trash rather than to nowhere. Offering it again per hunk would be the same action without
    /// either of those.
    ///
    /// **Disabled rather than hidden while ignoring whitespace**, because the rows on screen are a
    /// refold of git's patch (`FileDiff.ignoringWhitespace`) and their coordinates are not git's.
    /// The discard would find no matching hunk and refuse, which is the safe failure, but a control
    /// that always refuses is better drawn greyed with the reason on it.
    public static func availability(
        file: ChangedFile, scope: DiffScope, ignoringWhitespace: Bool, agentIsRunning: Bool
    ) -> Availability {
        guard !scope.isHistorical, !file.isBinary, targets(for: file.layer) != nil else { return .hidden }
        switch file.change {
        case .modified, .renamed, .copied: break
        case .added, .deleted, .untracked: return .hidden
        }
        if agentIsRunning { return .disabled(agentIsWorking) }
        if ignoringWhitespace { return .disabled(whitespaceIsHidden) }
        return .enabled
    }

    /// What pressing the control is meant to do, which is not the same thing in every scope.
    ///
    /// A reader looking at the whole comparison, or at the unstaged side, is looking at the
    /// worktree, and taking a hunk out of it is a discard: something somebody wrote is gone.
    /// A reader looking at the staged side is looking at the index, and there the ordinary git
    /// meaning of taking a hunk out is `restore --staged`, which unstages it and leaves the
    /// worktree's copy alone, so nothing is lost. Both are offered, and the word on the button has
    /// to be the one that matches, which is why this is a value rather than a comment.
    public enum Intent: Sendable, Hashable {
        /// The change leaves the file. Destructive, and the confirmation says so.
        case discard
        /// The change leaves the index only, and the worktree keeps it. `git restore --staged`.
        case unstage
    }

    /// Where a hunk from a diff of this layer lives, and so where reversing it has to happen.
    ///
    /// - No layer is the branch comparison, baseline to worktree. The hunk is in the worktree by
    ///   definition. It is in the index too when it was staged or committed, and then the index is
    ///   reversed as well, the way the file's own Discard checks the baseline out into both. A
    ///   hunk staged only in part fails to apply there and the index is left as it was.
    /// - Unstaged is index to worktree, so only the worktree holds it.
    /// - Staged is HEAD to index, and the intent decides. Discarding reverses both, because
    ///   reversing the index alone would leave the change sitting in the worktree, which is not a
    ///   discard, and a worktree copy edited again since staging is a refusal rather than half a
    ///   discard. Unstaging reverses the index and nothing else, which is the whole of what it is.
    /// - Conflicts and untracked files have no hunk to reverse on its own. Nil.
    /// - Unstaging anything but the staged side is nil: there is no index copy to take it out of,
    ///   and an unstage that quietly did a discard instead is the one mistake this must not make.
    public static func targets(for layer: ChangeLayer?, intent: Intent = .discard) -> Targets? {
        switch (layer, intent) {
        case (nil, .discard): Targets(worktree: .required, index: .whenPresent)
        case (.unstaged, .discard): Targets(worktree: .required, index: .untouched)
        case (.staged, .discard): Targets(worktree: .required, index: .required)
        case (.staged, .unstage): Targets(worktree: .untouched, index: .required)
        case (.conflicted, _), (.untracked, _), (nil, .unstage), (.unstaged, .unstage): nil
        }
    }

    /// The confirmation, which names the file because the band it was pressed on does not.
    public static func question(path: String) -> String {
        "Discard this hunk in \(path)?"
    }

    /// What the confirmation says is lost.
    public static func losses(of hunk: DiffHunk) -> String {
        let added = hunk.lines.filter { $0.kind == .addition }.count
        let removed = hunk.lines.filter { $0.kind == .deletion }.count
        let clauses = [
            removed > 0 ? "puts back \(Counted.of(removed, "removed line"))" : nil,
            added > 0 ? "takes out \(Counted.of(added, "added line"))" : nil,
        ].compactMap { $0 }
        let change = clauses.isEmpty ? "This undoes the change" : "This " + clauses.joined(separator: " and ")
        return change + ". The rest of the file is left as it is.\n\nThere is no undo for this."
    }
}

/// Why a hunk was not discarded. In every case nothing was written.
/// What a Discard says when the baseline its diff was drawn against has moved, typically because
/// the project checkout's `HEAD` was switched or committed since the list was read. The write is
/// refused rather than aimed at the new baseline: see `Git.revertTrackedFile`.
public struct StaleDiffTarget: Error, Sendable, Equatable, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "What this diff is compared with has moved since it was drawn, so nothing was discarded. "
            + "Look at the refreshed diff and discard again."
    }
}

public enum HunkDiscardRefusal: Error, Sendable, Equatable {
    /// Not a diff a hunk can be discarded from. The control should not have been drawn.
    case notOffered
    /// Git no longer reports the hunk that was on screen: the file changed under the diff.
    case changed
    /// The reverse patch does not apply to the worktree or to the index, with git's own words.
    case doesNotApply(String)
}

extension HunkDiscardRefusal: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notOffered:
            "A single hunk cannot be discarded from this diff."
        case .changed:
            "The file changed since this diff was drawn, so the hunk is not there any more. "
                + "Nothing was discarded."
        case let .doesNotApply(detail):
            "The hunk no longer applies cleanly, so nothing was discarded."
                + (detail.isEmpty ? "" : "\n\n" + detail)
        }
    }
}
