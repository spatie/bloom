import Foundation

/// Listing, adding and removing the worktrees a workspace is made of.
///
/// Everything in this file either makes something on disk or destroys it, so both destructive
/// calls take git's safe form first and reach for `--force` only when the caller asked: an
/// uncommitted file in a worktree exists nowhere else, and a branch whose commits are merged
/// nowhere becomes unreachable the moment the ref goes. Whether removing is safe in the first
/// place is a much more expensive question, and `Git+Safety.swift` is where it is asked.
///
/// `WorktreeEntry` and the parsing of `git worktree list --porcelain` are `WorktreeListing`, in
/// its own file, because which branches are already taken is a question the create window asks
/// before it is a question this file answers.

extension Git {
    public static func worktrees(of repo: String) async throws -> [WorktreeEntry] {
        WorktreeListing.parse(try await check(["worktree", "list", "--porcelain"], in: repo).stdout)
    }

    /// Cuts a worktree, creating the branch when it is not already there.
    ///
    /// - Parameter branchIsNew: whether the caller already knows `branch` does not exist, so the
    ///   `git show-ref` below can be skipped. Nil means ask git, which is right for every caller
    ///   that has not looked.
    ///
    ///   `WorkspaceManager.cut` has looked. It reads the whole branch list and builds the name
    ///   with `Git.uniqueBranch`, which returns something not in that list by construction, so
    ///   confirming it is a subprocess spent on a question already answered, on the path between
    ///   pressing Create and the workspace existing. Passing false rather than true is not a
    ///   shortcut worth taking anywhere: `worktree add -b` on a branch that does exist fails with
    ///   git's own words rather than doing something quiet and wrong, so a caller that gets this
    ///   backwards finds out immediately.
    public static func addWorktree(
        repo: String,
        path: String,
        branch: String,
        base: String,
        branchIsNew: Bool? = nil
    ) async throws {
        try validate(branch: branch)
        try validate(ref: base, label: "base branch")
        try validate(ref: path, label: "worktree path")

        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let exists = if let branchIsNew { !branchIsNew } else { await branchExists(branch, in: repo) }
        if exists {
            try await check(["worktree", "add", "--", path, branch], in: repo)
        } else {
            try await check(["worktree", "add", "-b", branch, "--", path, base], in: repo)
        }
    }

    /// Removes a worktree, refusing by default to throw away work.
    ///
    /// `force` defaults to false because `--force` makes git remove a dirty worktree without a
    /// word, and the files it deletes were never committed anywhere.
    public static func removeWorktree(repo: String, path: String, force: Bool = false) async throws {
        try validate(ref: path, label: "worktree path")

        // Always try the safe removal first, so a dirty worktree stops us even when the caller
        // asked for force for some other reason.
        var result = try await run(["worktree", "remove", "--", path], in: repo)
        if !result.ok, force {
            result = try await run(["worktree", "remove", "--force", "--", path], in: repo)
        }

        guard !result.ok else { return }

        // A worktree whose directory is already gone only needs pruning.
        try await run(["worktree", "prune"], in: repo)
        if FileManager.default.fileExists(atPath: path) {
            throw error(["worktree", "remove", path], result.status, result.stderr, result.stdout)
        }
    }

    /// Deletes a branch and reports whether git actually did it.
    ///
    /// The safe `-d` is the default: it refuses to delete a branch whose commits are not merged
    /// anywhere, which is exactly the case where the commits become unreachable. Swallowing the
    /// non-zero exit, as this used to, told the caller the branch was gone when it was not.
    public static func deleteBranch(_ branch: String, in repo: String, force: Bool = false) async throws {
        try validate(branch: branch)
        try await check(["branch", force ? "-D" : "-d", "--", branch], in: repo)
    }
}
