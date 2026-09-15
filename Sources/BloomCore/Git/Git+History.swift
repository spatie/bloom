import Foundation

extension Git {
    /// Include merge commits: their conflict resolutions are part of the work being reviewed.
    /// Date order keeps descendants above parents even when author clocks disagree.
    public static func branchCommits(
        worktree: String, base: String, limit: Int = BranchCommitList.limit
    ) async throws -> BranchCommitList {
        let mergeBase = try await baseline(base, in: worktree)
        let count = max(1, limit)
        let output = try await checkRaw([
            "log", "--date-order", "--max-count=\(count + 1)",
            "--format=%H%x00%s%x00%an%x00%aI%x00%P%x00%b%x00",
            "\(mergeBase)..HEAD", "--",
        ], in: worktree)
        let parsed = parseBranchCommits(output.stdout)
        return BranchCommitList(commits: Array(parsed.prefix(count)), isTruncated: parsed.count > count)
    }

    /// Fixed-width NUL records allow newlines and unit separators in messages and author names.
    static func parseBranchCommits(_ data: Data) -> [BranchCommit] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var commits: [BranchCommit] = []
        var index = 0
        while index + 5 < fields.count {
            let values = fields[index..<(index + 6)].map { String(decoding: $0, as: UTF8.self) }
            index += 6
            let sha = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty, let date = try? Date.ISO8601FormatStyle().parse(values[3]) else { continue }
            commits.append(BranchCommit(
                sha: sha, subject: values[1], author: values[2], date: date,
                body: values[5].trimmingCharacters(in: .whitespacesAndNewlines),
                parents: values[4].split(separator: " ").map(String.init)
            ))
        }
        return commits
    }

    /// Resolve the object rather than trusting metadata passed by a caller. A root commit
    /// compares with the empty tree in this repository's object format, without writing it.
    static func commitComparison(_ commit: BranchCommit, in worktree: String) async throws -> [String] {
        try validate(ref: commit.sha, label: "commit")
        let record = try await check(["rev-list", "--parents", "-n", "1", commit.sha, "--"], in: worktree)
        let objects = record.trimmed.split(separator: " ").map(String.init)
        guard let sha = objects.first else {
            throw error(["rev-list"], 1, "Commit could not be read.", "")
        }
        let parent: String
        if objects.count > 1 {
            parent = objects[1]
        } else {
            parent = try await check(["hash-object", "-t", "tree", "--stdin"], in: worktree, stdin: "").trimmed
        }
        return [parent, sha]
    }

    public static func containsCommit(_ commit: BranchCommit, worktree: String) async throws -> Bool {
        try validate(ref: commit.sha, label: "commit")
        let result = try await run(["merge-base", "--is-ancestor", commit.sha, "HEAD"], in: worktree)
        if result.status == 0 { return true }
        if result.status == 1 { return false }
        // A pruned object after a rebase also means that the selection has gone away.
        let object = try await run(["cat-file", "-e", "\(commit.sha)^{commit}"], in: worktree)
        if !object.ok { return false }
        throw error(["merge-base"], result.status, result.stderr, result.stdout)
    }

    /// The new side supplies expanded context. Reading today's file for an old commit or
    /// an index patch would put uncommitted lines inside a historical diff.
    public static func reviewContents(worktree: String, file: ChangedFile, scope: DiffScope) async throws -> String? {
        guard file.change != .deleted, !file.isBinary else { return nil }
        let object: String?
        if case .commit(let commit) = scope {
            try validate(ref: commit.sha, label: "commit")
            object = "\(commit.sha):\(file.path)"
        } else if file.layer == .staged {
            object = ":\(file.path)"
        } else {
            object = nil
        }
        if let object {
            return try await check(["show", object], in: worktree).stdout
        }
        return try? String(contentsOfFile: (worktree as NSString).appendingPathComponent(file.path), encoding: .utf8)
    }
}
