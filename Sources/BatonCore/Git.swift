import Foundation

public struct ChangedFile: Identifiable, Sendable, Hashable {
    public enum Change: String, Sendable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case untracked = "?"
    }

    public var path: String
    public var oldPath: String?
    public var change: Change
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool

    public var id: String { path }

    public var filename: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }

    public init(
        path: String,
        oldPath: String? = nil,
        change: Change,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.change = change
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }
}

public struct WorktreeEntry: Sendable, Hashable {
    public var path: String
    public var head: String
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
}

public enum Git {
    @discardableResult
    static func run(_ arguments: [String], in directory: String) async throws -> ShellResult {
        try await Shell.run("git", arguments, cwd: directory, env: [
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ])
    }

    @discardableResult
    static func check(_ arguments: [String], in directory: String) async throws -> ShellResult {
        let result = try await run(arguments, in: directory)
        guard result.ok else {
            throw ShellError(
                command: "git " + arguments.joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result
    }

    // MARK: - Repository facts

    public static func isRepository(_ path: String) async -> Bool {
        guard let result = try? await run(["rev-parse", "--is-inside-work-tree"], in: path) else {
            return false
        }
        return result.ok && result.trimmed == "true"
    }

    public static func topLevel(of path: String) async throws -> String {
        try await check(["rev-parse", "--show-toplevel"], in: path).trimmed
    }

    /// The branch a new workspace should be cut from. Prefers what origin points HEAD at, then
    /// the conventional names, then whatever is checked out.
    public static func defaultBranch(of repo: String) async throws -> String {
        let remote = try await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo)
        if remote.ok, case let value = remote.trimmed, value.hasPrefix("origin/") {
            return String(value.dropFirst("origin/".count))
        }
        for candidate in ["main", "master", "develop"] {
            let exists = try await run(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], in: repo)
            if exists.ok { return candidate }
        }
        return try await currentBranch(of: repo) ?? "main"
    }

    public static func currentBranch(of path: String) async throws -> String? {
        let result = try await run(["rev-parse", "--abbrev-ref", "HEAD"], in: path)
        guard result.ok else { return nil }
        let branch = result.trimmed
        return branch == "HEAD" ? nil : branch
    }

    public static func branches(of repo: String) async throws -> [String] {
        try await check(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repo).lines
    }

    public static func branchExists(_ branch: String, in repo: String) async -> Bool {
        let result = try? await run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)
        return result?.ok ?? false
    }

    public static func remoteURL(of repo: String) async throws -> String? {
        let result = try await run(["remote", "get-url", "origin"], in: repo)
        return result.ok ? result.trimmed : nil
    }

    public static func headSHA(of path: String) async throws -> String {
        try await check(["rev-parse", "HEAD"], in: path).trimmed
    }

    /// Commit the branch diverged from. Falls back to the base tip when there is no shared history.
    public static func mergeBase(_ base: String, _ head: String = "HEAD", in path: String) async throws -> String {
        let result = try await run(["merge-base", base, head], in: path)
        if result.ok, !result.trimmed.isEmpty { return result.trimmed }
        return try await check(["rev-parse", base], in: path).trimmed
    }

    // MARK: - Worktrees

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

    public static func addWorktree(
        repo: String,
        path: String,
        branch: String,
        base: String
    ) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        if await branchExists(branch, in: repo) {
            try await check(["worktree", "add", path, branch], in: repo)
        } else {
            try await check(["worktree", "add", "-b", branch, path, base], in: repo)
        }
    }

    public static func removeWorktree(repo: String, path: String, force: Bool = true) async throws {
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path)
        let result = try await run(arguments, in: repo)
        if !result.ok {
            // A worktree whose directory is already gone only needs pruning.
            try await run(["worktree", "prune"], in: repo)
            if FileManager.default.fileExists(atPath: path) {
                throw ShellError(
                    command: "git worktree remove",
                    status: result.status,
                    stderr: result.stderr
                )
            }
        }
    }

    public static func deleteBranch(_ branch: String, in repo: String, force: Bool = true) async throws {
        try await run(["branch", force ? "-D" : "-d", branch], in: repo)
    }

    // MARK: - Diffs

    /// Files changed on this worktree relative to where it diverged from `base`, including
    /// uncommitted work and untracked files.
    public static func changedFiles(worktree: String, base: String) async throws -> [ChangedFile] {
        let mergeBase = try await mergeBase(base, in: worktree)

        var byPath: [String: ChangedFile] = [:]

        let numstat = try await run(["diff", "--numstat", "-M", mergeBase, "--"], in: worktree)
        let nameStatus = try await run(["diff", "--name-status", "-M", mergeBase, "--"], in: worktree)

        var changeByPath: [String: (ChangedFile.Change, String?)] = [:]
        for line in nameStatus.lines {
            let parts = line.components(separatedBy: "\t")
            guard let code = parts.first?.first.map(String.init) else { continue }
            if code == "R", parts.count >= 3 {
                changeByPath[parts[2]] = (.renamed, parts[1])
            } else if parts.count >= 2 {
                changeByPath[parts[1]] = (ChangedFile.Change(rawValue: code) ?? .modified, nil)
            }
        }

        for line in numstat.lines {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let isBinary = parts[0] == "-"
            let path = parts.count > 3 ? parts[3] : parts[2]
            let (change, oldPath) = changeByPath[path] ?? (.modified, nil)
            byPath[path] = ChangedFile(
                path: path,
                oldPath: oldPath,
                change: change,
                additions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0,
                isBinary: isBinary
            )
        }

        // Untracked files never appear in `git diff`, but they are absolutely part of the change.
        let untracked = try await run(
            ["ls-files", "--others", "--exclude-standard"], in: worktree
        )
        for path in untracked.lines where byPath[path] == nil {
            let full = (worktree as NSString).appendingPathComponent(path)
            let lineCount = (try? String(contentsOfFile: full, encoding: .utf8))
                .map { $0.isEmpty ? 0 : $0.components(separatedBy: "\n").count } ?? 0
            byPath[path] = ChangedFile(
                path: path, change: .untracked, additions: lineCount, deletions: 0,
                isBinary: lineCount == 0 && FileManager.default.fileExists(atPath: full)
            )
        }

        return byPath.values.sorted { $0.path < $1.path }
    }

    public static func diffStat(worktree: String, base: String) async throws -> (files: Int, additions: Int, deletions: Int) {
        let files = try await changedFiles(worktree: worktree, base: base)
        return (
            files.count,
            files.reduce(0) { $0 + $1.additions },
            files.reduce(0) { $0 + $1.deletions }
        )
    }

    /// The unified patch for one file, in the same "since we diverged" sense as `changedFiles`.
    public static func patch(worktree: String, base: String, file: ChangedFile) async throws -> String {
        if file.change == .untracked {
            let result = try await run(
                ["diff", "--no-index", "--no-color", "/dev/null", file.path], in: worktree
            )
            // --no-index exits 1 whenever there is a difference, which is the normal case here.
            return result.stdout
        }
        let mergeBase = try await mergeBase(base, in: worktree)
        return try await run(
            ["diff", "--no-color", "-M", mergeBase, "--", file.path], in: worktree
        ).stdout
    }

    public static func fullPatch(worktree: String, base: String) async throws -> String {
        let mergeBase = try await mergeBase(base, in: worktree)
        return try await run(["diff", "--no-color", "-M", mergeBase], in: worktree).stdout
    }

    public static func hasUncommittedChanges(worktree: String) async throws -> Bool {
        !(try await check(["status", "--porcelain"], in: worktree).trimmed.isEmpty)
    }

    public static func commitsAhead(worktree: String, base: String) async throws -> Int {
        let result = try await run(["rev-list", "--count", "\(base)..HEAD"], in: worktree)
        return Int(result.trimmed) ?? 0
    }

    // MARK: - Naming

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with",
        "please", "can", "you", "i", "we", "it", "this", "that", "is", "are", "be",
        "should", "would", "could", "make", "let", "lets",
    ]

    /// Turn a prompt into a branch-safe slug. Mirrors what Conductor does: take the meaningful
    /// words from the first line, cap the length, keep it readable.
    public static func slug(from prompt: String, maxWords: Int = 5) -> String {
        let firstLine = prompt
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? prompt

        let words = firstLine
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var kept = words.filter { !stopWords.contains($0) && $0.count > 1 }
        if kept.isEmpty { kept = words }
        if kept.isEmpty { return "workspace" }

        let slug = kept.prefix(maxWords).joined(separator: "-")
        return String(slug.prefix(60))
    }

    /// A human-facing workspace name: the first line, trimmed and sentence-cased.
    public static func title(from prompt: String, maxLength: Int = 72) -> String {
        let firstLine = prompt
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !firstLine.isEmpty else { return "New workspace" }

        var title = firstLine
        if title.count > maxLength {
            let cut = title.prefix(maxLength)
            if let lastSpace = cut.lastIndex(of: " ") {
                title = String(cut[..<lastSpace])
            } else {
                title = String(cut)
            }
        }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// Append -2, -3 and so on until the branch name is free.
    public static func uniqueBranch(_ desired: String, taken: Set<String>) -> String {
        guard taken.contains(desired) else { return desired }
        var suffix = 2
        while taken.contains("\(desired)-\(suffix)") { suffix += 1 }
        return "\(desired)-\(suffix)"
    }
}
