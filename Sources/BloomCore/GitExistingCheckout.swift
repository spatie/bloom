import Foundation

/// Worktrees made for a head that already exists, rather than for a branch being cut.
///
/// `Git.addWorktree` cannot serve these. It cuts `-b <branch> <base>` when the branch is new,
/// which is exactly wrong for a branch that lives only on the remote: it would make a branch of
/// the same name off the local base and leave it looking like the contributor's work with none of
/// the commits in it.
public extension Git {
    /// A worktree on nothing in particular, for `gh pr checkout` to move onto the pull request.
    ///
    /// Detached at the current HEAD rather than at a branch, because every branch worth being on
    /// here is one the pull request is about to fetch, and a worktree holding a branch is a
    /// worktree git will not let anything else check that branch out into.
    static func addDetachedWorktree(repo: String, path: String, at revision: String = "HEAD") async throws {
        try validate(ref: revision, label: "revision")
        try validate(ref: path, label: "worktree path")

        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try await check(["worktree", "add", "--detach", "--", path, revision], in: repo)
    }

    /// A worktree on a branch that exists only on the remote, tracking it.
    ///
    /// `--track` matters beyond tidiness: `Git.baseline` looks for `refs/remotes/origin/<base>`
    /// and the review tab's "push" and pull request machinery both read the upstream. A branch
    /// made without one behaves like local work that has never been shared, which is the opposite
    /// of what has just been checked out.
    static func addTrackingWorktree(
        repo: String, path: String, branch: String, remote: String = Git.remote
    ) async throws {
        try validate(branch: branch)
        try validate(ref: path, label: "worktree path")
        try validate(ref: remote, label: "remote")

        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try await check(
            ["worktree", "add", "--track", "-b", branch, "--", path, "\(remote)/\(branch)"],
            in: repo
        )
    }

    /// Every remote-tracking branch, as `origin/name`.
    ///
    /// Nothing is fetched first. The picker draws what this checkout already knows about, which is
    /// what makes it instant, and a branch pushed in the last minute is the price. `Git.fetch` is
    /// the caller's to run when it wants the newer list.
    static func remoteBranches(of repo: String) async throws -> [String] {
        try await check(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes"], in: repo
        ).lines
    }
}
