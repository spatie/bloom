import Foundation

/// What a directory Bloom recorded turns out to be, asked once something has already failed in it.
///
/// Every surface that runs git in a recorded path has the same problem the moment the path stops
/// being a checkout: git's stderr is the same eight words for several different situations, and one
/// of them is not even reached, because launching a subprocess in a deleted directory throws a
/// Cocoa error naming only the last path component before git runs at all. `WorkspaceStartTrouble`
/// answered that by asking the repository three questions instead of reading the stderr, and this
/// is those questions on their own, so the sheet, the diff pane and the tool all ask them once and
/// cannot disagree about the answer.
///
/// The order matters and is not arbitrary. A path that is not there cannot be a checkout, a
/// directory git does not know has no commits to look for, and a repository with no commits has
/// no branches, so each question is only worth asking once the one before it has been answered.
public enum CheckoutStanding: Sendable, Equatable {
    /// Nothing at the path at all. Deleted, moved or renamed since Bloom wrote it down.
    case missing
    /// A directory is there, and git does not know it: no `.git` in it or above it.
    case notACheckout
    /// A repository that has never been committed to, so there is no commit to work from.
    case noCommitsYet
    /// The branch that was being worked from is not in this repository.
    case branchMissing(String)
    /// The checkout is intact and the branch is there, so whatever failed failed for another
    /// reason.
    case fine

    /// Asks the path itself, rather than reading what git said about it.
    ///
    /// - Parameter branch: the branch the caller needs, or nil when it does not need one. A
    ///   worktree shares its refs with the repository it was cut from, so this answers the same
    ///   whether it is asked of a project or of one of its worktrees.
    public static func of(_ path: String, branch: String? = nil) async -> CheckoutStanding {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard await Git.isRepository(path) else { return .notACheckout }
        guard await Git.hasCommits(in: path) else { return .noCommitsYet }
        if let branch, !(await Git.branchExists(branch, in: path)) { return .branchMissing(branch) }
        return .fine
    }

    /// git's complaint without the command line Bloom built to provoke it.
    ///
    /// `ShellError.description` exists for a log, where the argv is the most useful thing in it.
    /// In front of a person, or of a model, it is the least useful: it is the one part of the
    /// failure the reader neither chose nor can change, and it invites them to reason about git
    /// rather than about what they were doing.
    public static func complaint(about error: any Error) -> String {
        guard let shell = error as? ShellError else { return error.readableMessage }
        let stderr = shell.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stderr.isEmpty else { return "git exited \(shell.status) without saying why." }
        return stderr.hasSuffix(".") ? stderr : stderr + "."
    }
}
