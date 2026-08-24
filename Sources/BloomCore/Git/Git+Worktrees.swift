import Foundation

/// Listing, adding and removing the worktrees a workspace is made of.
///
/// Everything in this file either makes something on disk or destroys it, so both destructive
/// calls take git's safe form first and reach for `--force` only when the caller asked: an
/// uncommitted file in a worktree exists nowhere else, and a branch whose commits are merged
/// nowhere becomes unreachable the moment the ref goes. Whether removing is safe in the first
/// place is a much more expensive question, and `Git+Safety.swift` is where it is asked.
///
/// `WorktreeEntry` is one record of `git worktree list --porcelain`, parsed.
public struct WorktreeEntry: Sendable, Hashable {
    public var path: String
    public var head: String
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
}

extension Git {
    public static func worktrees(of repo: String) async throws -> [WorktreeEntry] {
        let output = try await check(["worktree", "list", "--porcelain"], in: repo).stdout
        var entries: [WorktreeEntry] = []
        var path: String?
        var head = ""
        var branch: String?
        var bare = false
        var detached = false

        func flush() {
            guard let path else { return }
            entries.append(WorktreeEntry(
                path: path, head: head, branch: branch, isBare: bare, isDetached: detached
            ))
        }

        for line in output.components(separatedBy: "\n") {
            if line.isEmpty {
                flush()
                path = nil; head = ""; branch = nil; bare = false; detached = false
                continue
            }
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "bare" {
                bare = true
            } else if line == "detached" {
                detached = true
            }
        }
        flush()
        return entries
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
