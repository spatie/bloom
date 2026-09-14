import Foundation

extension Git {
    /// `--` ends options, but leaves globbing and pathspec magic enabled. A route named
    /// `[id].tsx` must never restore its neighbours `i.tsx` and `d.tsx` as well.
    static func literalPaths(_ arguments: [String]) -> [String] {
        ["--literal-pathspecs"] + arguments
    }

    /// Reverts a tracked file to the same baseline the review shows. Untracked files belong
    /// to the app's Trash operation, because Git has no recoverable version of them.
    public static func revertTrackedFile(_ file: ChangedFile, worktree: String, base: String) async throws {
        guard file.change != .untracked else {
            throw error(["restore"], 1, "Untracked files must be moved to the Trash.", "")
        }
        let revision = try await baseline(base, in: worktree)
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
}
