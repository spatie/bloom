import Foundation

extension Git {
    /// `--` ends options, but leaves globbing and pathspec magic enabled. A route named
    /// `[id].tsx` must never restore its neighbours `i.tsx` and `d.tsx` as well.
    static func literalPaths(_ arguments: [String]) -> [String] {
        ["--literal-pathspecs"] + arguments
    }

    /// Reverts a tracked file to the same baseline the review shows. Untracked files belong
    /// to the app's Trash operation, because Git has no recoverable version of them.
    ///
    /// `expected` is the baseline the list on screen was drawn against. The baseline is resolved
    /// again here, because this is the write, and when it is no longer that commit nothing is
    /// written: the file on screen was compared with something else, and restoring it to what the
    /// base is now would delete or reverse work the reader never saw in the diff. Nil skips the
    /// check, for a caller that resolved nothing beforehand.
    public static func revertTrackedFile(
        _ file: ChangedFile, worktree: String, base: String, expected: String? = nil
    ) async throws {
        guard file.change != .untracked else {
            throw error(["restore"], 1, "Untracked files must be moved to the Trash.", "")
        }
        let revision = try await baseline(base, in: worktree)
        if let expected, expected != revision { throw StaleDiffTarget() }
        if file.change == .renamed, let oldPath = file.oldPath {
            try await check(literalPaths(["checkout", revision, "--", oldPath]), in: worktree)
            try await check(literalPaths(["rm", "-f", "--", file.path]), in: worktree)
            return
        }
        let exists = try await run(["cat-file", "-e", "\(revision):\(file.path)"], in: worktree)
        if exists.ok {
            try await check(literalPaths(["checkout", revision, "--", file.path]), in: worktree)
        } else {
            try await check(literalPaths(["rm", "-f", "--", file.path]), in: worktree)
        }
    }

    /// Takes `file` out of the index and leaves the worktree alone: `git restore --staged`.
    ///
    /// This is what Discard means to somebody reading the staged side on its own, and it is the
    /// ordinary git meaning, so a person who knows git is not surprised and a person who does not
    /// is not robbed: nothing anybody wrote is destroyed, the change is simply no longer part of
    /// the next commit. A staged rename names both paths, or the old one would stay staged as a
    /// deletion.
    public static func unstageFile(_ file: ChangedFile, worktree: String) async throws {
        try await check(literalPaths(["restore", "--staged", "--"] + paths(of: file)), in: worktree)
    }

    /// Puts the worktree's copy of `file` back to the index's: `git restore`.
    ///
    /// This is what Discard means on the unstaged side, and there it really is a discard: the
    /// index to the worktree is the only comparison where the change exists nowhere else, so
    /// throwing the worktree's copy away is the only thing the word can mean.
    public static func restoreWorktreeFile(_ file: ChangedFile, worktree: String) async throws {
        try await check(literalPaths(["restore", "--worktree", "--"] + paths(of: file)), in: worktree)
    }

    /// Both ends of a rename, or the one path there is.
    private static func paths(of file: ChangedFile) -> [String] {
        file.oldPath.map { [$0, file.path] } ?? [file.path]
    }
}
