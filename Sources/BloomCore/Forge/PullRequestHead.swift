import Foundation

/// Which branch a workspace's pull request should be looked up by.
///
/// A workspace records the branch it was created on, and every pull request lookup used to name
/// that record. It stops being true the moment the agent moves the worktree, which agents do: a
/// reset, a `checkout -b` from `origin/main`, a branch renamed to suit the issue it turned out to
/// be about. The work is then on a name Bloom never wrote down.
///
/// That is a real report rather than a hypothetical. An agent opened a pull request, said so in
/// the transcript, and the strip went on saying "No pull request yet. Target main." with a Create
/// pull request button over it for as long as the workspace was open. Nothing was stale: every
/// poll asked gh again, with no cached answer, and got the same nothing back, because
/// `gh pr view <recorded branch>` is a question about a branch that was never pushed. The unnamed
/// fallback in `GitHub.snapshotOfCheckedOutBranch` did find the pull request, and then threw it
/// away again for not matching the name it had been asked about. A button that opens a second
/// pull request for work that already has one is the worst thing that strip can do, so the
/// question is asked about the branch the worktree is on **now**.
///
/// Two cases keep the recorded name, both because the live one asks a worse question:
///
/// - **A detached HEAD has no branch at all**, which is a rebase, a bisect, or a commit checked
///   out to look at. The recorded name is then the only name there is.
/// - **A worktree standing on the base branch** is between branches rather than on one of its
///   own. `gh pr view main` is a question about somebody's fork of this repository, not about this
///   workspace, and it can answer with a pull request that has nothing to do with either.
public enum PullRequestHead {
    /// - Parameter recorded: `Workspace.branch`, the name written when the workspace was created.
    /// - Parameter checkedOut: what `git rev-parse --abbrev-ref HEAD` says now, or nil for a
    ///   detached HEAD. See `Git.currentBranch`.
    /// - Parameter base: `Workspace.baseBranch`.
    public static func branch(recorded: String, checkedOut: String?, base: String) -> String {
        let live = (checkedOut ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !live.isEmpty else { return recorded }
        // A row with no branch name in it is not a name to prefer. Old rows have one, and
        // `Store.workspace(from:)` reads a missing column as the empty string.
        guard !recorded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return live }
        return live == base ? recorded : live
    }
}
