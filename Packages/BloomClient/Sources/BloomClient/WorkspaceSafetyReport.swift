import Foundation

/// What throwing a workspace away would destroy.
///
/// Removing a worktree and deleting its branch leaves nothing to recover from: the files are
/// gone from disk and, once no ref points at them, the commits are unreachable and eventually
/// pruned. So every field here is computed and shown before anything is deleted.
public struct WorkspaceSafetyReport: Codable, Sendable, Hashable {
    /// Tracked files with modifications that were never committed.
    public var hasUncommittedChanges: Bool
    /// Files git has never seen. These are the easiest to lose and the hardest to notice.
    public var untrackedFiles: [String]
    /// Commits reachable from this branch and from no other ref in the repository. Nothing
    /// else, local or remote, is holding on to them.
    public var unpushedCommits: Int
    /// Whether the base branch already contains this branch's history.
    public var isBranchMerged: Bool
    /// Ignored paths that differ from the main checkout, or exist only here, minus everything a
    /// tool can rebuild. A trailing slash means a whole directory, named once.
    ///
    /// `git status --porcelain` does not list ignored files and `git worktree remove` deletes them
    /// without a word, so these were invisible. Bloom copies `.env*` into every worktree, which
    /// makes an edited `.env` both the likeliest file to be destroyed and the one nobody would
    /// think to check. What is NOT here, and why, is `ReproduciblePaths`.
    public var modifiedIgnoredFiles: [String]
    /// Commits held only by this worktree's own HEAD, on no branch at all.
    ///
    /// An agent that runs `git checkout` leaves HEAD detached. Commits made after that belong to
    /// no ref, so counting commits on the branch misses them entirely, and removing the worktree
    /// throws away the per-worktree reflog that was the last thing holding them.
    public var detachedCommits: Int

    /// Archiving only updates the record when this folder is no longer a checkout.
    /// Its files, branch and Git metadata are kept, and the archive script is skipped.
    public var preservedFolderPath: String?

    public init(
        hasUncommittedChanges: Bool = false,
        untrackedFiles: [String] = [],
        unpushedCommits: Int = 0,
        isBranchMerged: Bool = false,
        modifiedIgnoredFiles: [String] = [],
        detachedCommits: Int = 0
    ) {
        self.hasUncommittedChanges = hasUncommittedChanges
        self.untrackedFiles = untrackedFiles
        self.unpushedCommits = unpushedCommits
        self.isBranchMerged = isBranchMerged
        self.modifiedIgnoredFiles = modifiedIgnoredFiles
        self.detachedCommits = detachedCommits
    }

    /// A merged branch's commits live on in the base branch, so they are not counted as a loss.
    ///
    /// The cautious form of the question: it assumes the branch is being deleted along with the
    /// worktree, and it knows only what git knows. Callers with better information should ask
    /// `isSafeToDiscard(deletingBranch:isPullRequestMerged:)` instead.
    public var isSafeToDiscard: Bool {
        isSafeToDiscard(deletingBranch: true)
    }

    /// Whether archiving destroys anything, given the two things a git process cannot see.
    ///
    /// - Parameter deletingBranch: whether the branch goes with the worktree. Committed work is
    ///   only ever at risk when it does. A worktree is a checkout: remove it while the branch
    ///   survives and every commit is still on the branch, which is the same reasoning
    ///   `isRestorableFromBranch` is built on and the reason that archive can be undone.
    /// - Parameter isPullRequestMerged: GitHub says the pull request for this branch was merged.
    ///   Only ever passed `true` when GitHub actually said so, never inferred from its silence,
    ///   because being wrong here is only dangerous in one direction. It matters because
    ///   `isBranchMerged` is git's reachability test, and a squash merge rewrites the branch's
    ///   commits onto the base rather than joining its history to it. Git's answer for a squash
    ///   merged branch is "not merged" while every line of its work is already on main, and that
    ///   is the single most common way this check is wrong.
    public func isSafeToDiscard(deletingBranch: Bool, isPullRequestMerged: Bool = false) -> Bool {
        // Everything git was keeping no copy of. It lives in the worktree directory and nowhere
        // else, so it goes whether the branch survives or not.
        let workingCopyIsClean = !hasUncommittedChanges
            && untrackedFiles.isEmpty
            && modifiedIgnoredFiles.isEmpty
            && detachedCommits == 0

        guard workingCopyIsClean else { return false }
        guard deletingBranch else { return true }
        return unpushedCommits == 0 || isBranchMerged || isPullRequestMerged
    }

    /// One line per thing that would be destroyed, for an error message or a confirmation sheet.
    public var losses: [String] {
        losses(deletingBranch: true)
    }

    /// The same list, narrowed to what is actually at stake for this particular archive.
    ///
    /// A confirmation that lists commits as a loss when the branch is being kept is a
    /// confirmation nobody will read twice. See `isSafeToDiscard(deletingBranch:)` for both
    /// arguments.
    ///
    /// Everything, in one voice, which is right for `WorkspaceError.unsafeToArchive` and wrong
    /// for the confirmation. The confirmation asks for the two halves separately. See
    /// `irreversibleLosses(deletingBranch:isPullRequestMerged:)`.
    public func losses(deletingBranch: Bool, isPullRequestMerged: Bool = false) -> [String] {
        irreversibleLosses(deletingBranch: deletingBranch, isPullRequestMerged: isPullRequestMerged)
            + ignoredFileNotes
    }

    /// The half of the list that is genuinely gone for good: work git was keeping no other copy
    /// of, and commits nothing else points at.
    ///
    /// Split out from `ignoredFileNotes` because saying both in one red sentence is how a
    /// destructive button stops being read. The owner merged a pull request, pressed Archive, and
    /// was offered "Archive and lose that work" over thirteen ignored paths: a `.env`, generated
    /// route and type files, an attachments folder. None of that was ever in a commit, none of it
    /// was meant to be, and the code itself was already on the default branch. Spending the
    /// strongest words in the app on that teaches people to click through them, which is the last
    /// thing wanted on the one action that cannot be undone.
    public func irreversibleLosses(
        deletingBranch: Bool, isPullRequestMerged: Bool = false
    ) -> [String] {
        var losses: [String] = []
        if hasUncommittedChanges {
            losses.append("uncommitted changes to tracked files")
        }
        if !untrackedFiles.isEmpty {
            let sample = untrackedFiles.prefix(5).joined(separator: ", ")
            let rest = untrackedFiles.count > 5 ? ", and \(untrackedFiles.count - 5) more" : ""
            losses.append("\(Self.count(untrackedFiles.count, "untracked file")): \(sample)\(rest)")
        }
        if deletingBranch, unpushedCommits > 0, !isBranchMerged, !isPullRequestMerged {
            losses.append(
                "\(Self.count(unpushedCommits, "commit")) that "
                + "\(unpushedCommits == 1 ? "exists" : "exist") on no other branch, tag or remote"
            )
        }
        if detachedCommits > 0 {
            losses.append(
                "\(Self.count(detachedCommits, "commit")) made on a detached HEAD, "
                + "held by no branch"
            )
        }
        return losses
    }

    /// The half worth mentioning rather than warning about: ignored paths that differ from the
    /// main checkout.
    ///
    /// Still said out loud, because `git worktree remove` really does delete them and nothing
    /// else in the app would tell anyone. Never called a loss, because git was never holding a
    /// copy to lose: these are files a `.gitignore` deliberately keeps out of every commit.
    /// `ReproduciblePaths` has already dropped everything a package manager could put back, which
    /// is what makes naming the rest worth the reader's time.
    public var ignoredFileNotes: [String] {
        guard !modifiedIgnoredFiles.isEmpty else { return [] }

        let sample = modifiedIgnoredFiles.prefix(5).joined(separator: ", ")
        let rest = modifiedIgnoredFiles.count > 5
            ? ", and \(modifiedIgnoredFiles.count - 5) more"
            : ""
        // A trailing slash means the entry is a whole directory, named once, so the noun has to
        // allow for one.
        let folders = modifiedIgnoredFiles.contains { $0.hasSuffix("/") }
        let one = modifiedIgnoredFiles.count == 1
        let noun = switch (one, folders) {
        case (true, true): "ignored folder"
        case (true, false): "ignored file"
        case (false, true): "ignored files and folders"
        case (false, false): "ignored files"
        }
        return [
            "\(modifiedIgnoredFiles.count) \(noun) that \(one ? "differs" : "differ") "
            + "from the main checkout: \(sample)\(rest)"
        ]
    }

    /// "1 untracked file", "3 untracked files". The list this feeds is read at the moment somebody
    /// decides whether to destroy their work, which is the worst place in the app for the reader to
    /// have to translate "file(s)" for themselves.
    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}
