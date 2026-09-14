import Foundation

extension Git {
    /// A turn's footer describes its net file changes, including shell writes and files edited
    /// several times. Only the two saved trees participate, so later work cannot change it.
    public static func snapshotFiles(
        from before: GitSnapshot, to after: GitSnapshot, in worktree: String
    ) async throws -> [ChangedFile] {
        guard UUID(uuidString: before.id.rawValue) != nil, UUID(uuidString: after.id.rawValue) != nil else {
            throw SnapshotFailure("Invalid snapshot identifier.")
        }
        let range = [before.worktreeRef + "^{tree}", after.worktreeRef + "^{tree}", "--"]
        let options = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames"]
        async let namesRead = checkRaw(literalPaths(options + ["--name-status", "-z"] + range), in: worktree)
        async let countsRead = checkRaw(literalPaths(options + ["--numstat", "-z"] + range), in: worktree)
        let names = try await namesRead
        let counts = try await countsRead
        // A replacement character could name another real file when the footer opens its diff.
        guard String(data: names.stdout, encoding: .utf8) != nil,
              String(data: counts.stdout, encoding: .utf8) != nil else {
            throw SnapshotFailure("A snapshot filename cannot be represented safely.")
        }
        let changes = parseNameStatus(names.stdout)
        var files = parseNumstat(counts.stdout, changes: changes)
        for (path, change) in changes where files[path] == nil {
            files[path] = ChangedFile(path: path, oldPath: change.1, change: change.0)
        }
        return files.values.sorted { $0.path < $1.path }
    }
}
