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

/// What throwing a workspace away would destroy.
///
/// Removing a worktree and deleting its branch leaves nothing to recover from: the files are
/// gone from disk and, once no ref points at them, the commits are unreachable and eventually
/// pruned. So every field here is computed and shown before anything is deleted.
public struct WorkspaceSafetyReport: Sendable, Hashable {
    /// Tracked files with modifications that were never committed.
    public var hasUncommittedChanges: Bool
    /// Files git has never seen. These are the easiest to lose and the hardest to notice.
    public var untrackedFiles: [String]
    /// Commits reachable from this branch and from no other ref in the repository. Nothing
    /// else, local or remote, is holding on to them.
    public var unpushedCommits: Int
    /// Whether the base branch already contains this branch's history.
    public var isBranchMerged: Bool
    /// Ignored files that differ from the main checkout, or exist only here.
    ///
    /// `git status --porcelain` does not list ignored files and `git worktree remove` deletes them
    /// without a word, so these were invisible. Bloom copies `.env*` into every worktree, which
    /// makes an edited `.env` both the likeliest file to be destroyed and the one nobody would
    /// think to check.
    public var modifiedIgnoredFiles: [String]
    /// Commits held only by this worktree's own HEAD, on no branch at all.
    ///
    /// An agent that runs `git checkout` leaves HEAD detached. Commits made after that belong to
    /// no ref, so counting commits on the branch misses them entirely, and removing the worktree
    /// throws away the per-worktree reflog that was the last thing holding them.
    public var detachedCommits: Int

    public init(
        hasUncommittedChanges: Bool = false,
        untrackedFiles: [String] = [],
        unpushedCommits: Int = 0,
        isBranchMerged: Bool = false,
        modifiedIgnoredFiles: [String] = [],
        detachedCommits: Int = 0
    ) {
        self.hasUncommittedChanges = hasUncommittedChanges
        self.untrackedFiles = untrackedFiles
        self.unpushedCommits = unpushedCommits
        self.isBranchMerged = isBranchMerged
        self.modifiedIgnoredFiles = modifiedIgnoredFiles
        self.detachedCommits = detachedCommits
    }

    /// A merged branch's commits live on in the base branch, so they are not counted as a loss.
    ///
    /// The cautious form of the question: it assumes the branch is being deleted along with the
    /// worktree, and it knows only what git knows. Callers with better information should ask
    /// `isSafeToDiscard(deletingBranch:isPullRequestMerged:)` instead.
    public var isSafeToDiscard: Bool {
        isSafeToDiscard(deletingBranch: true)
    }

    /// Whether archiving destroys anything, given the two things a git process cannot see.
    ///
    /// - Parameter deletingBranch: whether the branch goes with the worktree. Committed work is
    ///   only ever at risk when it does. A worktree is a checkout: remove it while the branch
    ///   survives and every commit is still on the branch, which is the same reasoning
    ///   `isRestorableFromBranch` is built on and the reason that archive can be undone.
    /// - Parameter isPullRequestMerged: GitHub says the pull request for this branch was merged.
    ///   Only ever passed `true` when GitHub actually said so, never inferred from its silence,
    ///   because being wrong here is only dangerous in one direction. It matters because
    ///   `isBranchMerged` is git's reachability test, and a squash merge rewrites the branch's
    ///   commits onto the base rather than joining its history to it. Git's answer for a squash
    ///   merged branch is "not merged" while every line of its work is already on main, and that
    ///   is the single most common way this check is wrong.
    public func isSafeToDiscard(deletingBranch: Bool, isPullRequestMerged: Bool = false) -> Bool {
        // Everything git was keeping no copy of. It lives in the worktree directory and nowhere
        // else, so it goes whether the branch survives or not.
        let workingCopyIsClean = !hasUncommittedChanges
            && untrackedFiles.isEmpty
            && modifiedIgnoredFiles.isEmpty
            && detachedCommits == 0

        guard workingCopyIsClean else { return false }
        guard deletingBranch else { return true }
        return unpushedCommits == 0 || isBranchMerged || isPullRequestMerged
    }

    /// One line per thing that would be destroyed, for an error message or a confirmation sheet.
    public var losses: [String] {
        losses(deletingBranch: true)
    }

    /// The same list, narrowed to what is actually at stake for this particular archive.
    ///
    /// A confirmation that lists commits as a loss when the branch is being kept is a
    /// confirmation nobody will read twice. See `isSafeToDiscard(deletingBranch:)` for both
    /// arguments.
    public func losses(deletingBranch: Bool, isPullRequestMerged: Bool = false) -> [String] {
        var losses: [String] = []
        if hasUncommittedChanges {
            losses.append("uncommitted changes to tracked files")
        }
        if !untrackedFiles.isEmpty {
            let sample = untrackedFiles.prefix(5).joined(separator: ", ")
            let rest = untrackedFiles.count > 5 ? ", and \(untrackedFiles.count - 5) more" : ""
            losses.append("\(Self.count(untrackedFiles.count, "untracked file")): \(sample)\(rest)")
        }
        if !modifiedIgnoredFiles.isEmpty {
            let sample = modifiedIgnoredFiles.prefix(5).joined(separator: ", ")
            let rest = modifiedIgnoredFiles.count > 5
                ? ", and \(modifiedIgnoredFiles.count - 5) more"
                : ""
            losses.append(
                "\(Self.count(modifiedIgnoredFiles.count, "ignored file")) that "
                + "\(modifiedIgnoredFiles.count == 1 ? "differs" : "differ") "
                + "from the main checkout: \(sample)\(rest)"
            )
        }
        if deletingBranch, unpushedCommits > 0, !isBranchMerged, !isPullRequestMerged {
            losses.append(
                "\(Self.count(unpushedCommits, "commit")) that "
                + "\(unpushedCommits == 1 ? "exists" : "exist") on no other branch, tag or remote"
            )
        }
        if detachedCommits > 0 {
            losses.append(
                "\(Self.count(detachedCommits, "commit")) made on a detached HEAD, "
                + "held by no branch"
            )
        }
        return losses
    }

    /// "1 untracked file", "3 untracked files". The list this feeds is read at the moment somebody
    /// decides whether to destroy their work, which is the worst place in the app for the reader to
    /// have to translate "file(s)" for themselves.
    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

/// A finished git process whose stdout is kept as bytes.
///
/// Paths are byte strings on macOS and Linux, and git's `-z` output hands them back verbatim.
/// Decoding stdout to a `String` first would silently rewrite anything that is not valid UTF-8,
/// so the parsers work from `Data` and decode one field at a time.
struct GitOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String

    var ok: Bool { status == 0 }
}

public enum Git {
    @discardableResult
    static func run(
        _ arguments: [String],
        in directory: String,
        stdin: String? = nil
    ) async throws -> ShellResult {
        try await Shell.run("git", arguments, cwd: directory, env: [
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ], stdin: stdin)
    }

    @discardableResult
    static func check(
        _ arguments: [String],
        in directory: String,
        stdin: String? = nil
    ) async throws -> ShellResult {
        let result = try await run(arguments, in: directory, stdin: stdin)
        guard result.ok else { throw error(arguments, result.status, result.stderr, result.stdout) }
        return result
    }

    static func error(_ arguments: [String], _ status: Int32, _ stderr: String, _ stdout: String) -> ShellError {
        ShellError(
            command: "git " + arguments.joined(separator: " "),
            status: status,
            stderr: stderr.isEmpty ? stdout : stderr
        )
    }

    /// Same contract as `run`, but stdout is not decoded. Used for the `-z` parsers.
    static func runRaw(_ arguments: [String], in directory: String) async throws -> GitOutput {
        guard let executable = Shell.which("git") else {
            throw ShellError(command: "git", status: 127, stderr: "git not found on PATH")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Shell.environment(extra: [
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ])
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = ByteCollector()
        // Both pipes have to be drained while the process runs, or a large diff fills the buffer
        // and git blocks forever on write. A reader thread per pipe rather than a
        // `readabilityHandler`, because clearing the handler once the process exits can discard
        // what the dispatch source had already buffered. That showed up as `git diff` returning
        // nothing at all, which `changedFiles` would have reported as a clean worktree.
        let outReader = Thread {
            collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
            collector.finishOut()
        }
        let errReader = Thread {
            collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
            collector.finishErr()
        }
        outReader.stackSize = 512 * 1_024
        errReader.stackSize = 512 * 1_024

        try process.run()

        outReader.start()
        errReader.start()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        // Exit does not mean the output is complete. Both pipes have to reach EOF first.
        await collector.waitForEOF()

        return GitOutput(
            status: process.terminationStatus,
            stdout: collector.out,
            stderr: String(decoding: collector.err, as: UTF8.self)
        )
    }

    /// `runRaw` that refuses to hand back output from a failed command.
    ///
    /// A broken repository, a base branch that no longer exists or a contended `index.lock` all
    /// exit non-zero with empty stdout. Treating that as "no changes" shows a clean worktree to
    /// someone who has plenty of work in it, which is the worst possible lie to tell here.
    static func checkRaw(_ arguments: [String], in directory: String) async throws -> GitOutput {
        let result = try await runRaw(arguments, in: directory)
        guard result.ok else {
            throw error(arguments, result.status, result.stderr, String(decoding: result.stdout, as: UTF8.self))
        }
        return result
    }

    // MARK: - Ref safety

    /// Whether git would accept this as a branch name, following `git check-ref-format --branch`.
    ///
    /// This is a guard, not a convenience. Git happily creates a branch literally called
    /// `--mirror`, and a bare `git push origin --mirror` then deletes every remote ref that has
    /// no local counterpart. Rejecting the name is cheaper than trusting every call site to
    /// terminate its options correctly.
    public static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "HEAD" else { return false }
        // An argument starting with a dash is an option to nearly every git subcommand.
        guard !name.hasPrefix("-") else { return false }
        guard !name.hasPrefix("/"), !name.hasSuffix("/") else { return false }
        guard !name.hasSuffix(".") else { return false }
        guard !name.contains(".."), !name.contains("@{"), !name.contains("//") else { return false }

        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            if " ~^:?*[\\".unicodeScalars.contains(scalar) { return false }
        }

        for component in name.components(separatedBy: "/") {
            if component.isEmpty || component.hasPrefix(".") || component.hasSuffix(".lock") {
                return false
            }
        }
        return true
    }

    /// Rejects a ref that git would read as an option. Refs reach us from settings files, from
    /// branch names an agent invented and from the store, so none of them are trusted.
    static func validate(ref: String, label: String = "ref") throws {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains("\0") else {
            throw ShellError(
                command: "git",
                status: 128,
                stderr: "refusing to use \(ref.isEmpty ? "an empty" : "the unsafe") \(label) '\(ref)'"
            )
        }
    }

    static func validate(branch: String) throws {
        guard isValidBranchName(branch) else {
            throw ShellError(
                command: "git",
                status: 128,
                stderr: "'\(branch)' is not a valid branch name"
            )
        }
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
        guard isValidBranchName(branch) else { return false }
        let result = try? await run(["show-ref", "--verify", "--quiet", "--", "refs/heads/\(branch)"], in: repo)
        return result?.ok ?? false
    }

    public static func headSHA(of path: String) async throws -> String {
        try await check(["rev-parse", "HEAD"], in: path).trimmed
    }

    /// Commit the branch diverged from. Falls back to the base tip when there is no shared history.
    ///
    /// Throws when `base` cannot be resolved at all. A missing base branch used to surface as an
    /// empty diff, which reads as "this workspace changed nothing".
    public static func mergeBase(_ base: String, _ head: String = "HEAD", in path: String) async throws -> String {
        try validate(ref: base, label: "base branch")
        try validate(ref: head, label: "revision")
        let result = try await run(["merge-base", base, head], in: path)
        if result.ok, !result.trimmed.isEmpty { return result.trimmed }
        return try await check(["rev-parse", "--verify", "\(base)^{commit}"], in: path).trimmed
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
        try validate(branch: branch)
        try validate(ref: base, label: "base branch")
        try validate(ref: path, label: "worktree path")

        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        if await branchExists(branch, in: repo) {
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

    // MARK: - Diffs

    /// Files changed on this worktree relative to where it diverged from `base`, including
    /// uncommitted work and untracked files.
    ///
    /// Everything here runs with `-z` and is parsed from bytes. Git's default output C-quotes any
    /// path that is not plain ASCII and separates fields with tab and newline, both of which a
    /// path is allowed to contain. Splitting that text gave `"caf\303\251.txt"` for `café.txt`
    /// and cut a path containing a tab in half.
    ///
    /// Throws if any of the git calls fail, because an empty list has to mean "nothing changed"
    /// and never "we could not find out".
    public static func changedFiles(worktree: String, base: String) async throws -> [ChangedFile] {
        let mergeBase = try await mergeBase(base, in: worktree)

        let nameStatus = try await checkRaw(
            ["diff", "--name-status", "-M", "-z", mergeBase, "--"], in: worktree
        )
        let numstat = try await checkRaw(
            ["diff", "--numstat", "-M", "-z", mergeBase, "--"], in: worktree
        )
        let untracked = try await checkRaw(
            ["ls-files", "--others", "--exclude-standard", "-z"], in: worktree
        )

        let changeByPath = parseNameStatus(nameStatus.stdout)
        var byPath = parseNumstat(numstat.stdout, changes: changeByPath)

        // Untracked files never appear in `git diff`, but they are absolutely part of the change.
        for record in nulRecords(untracked.stdout) {
            let path = String(decoding: record, as: UTF8.self)
            guard !path.isEmpty, byPath[path] == nil else { continue }
            let full = (worktree as NSString).appendingPathComponent(path)
            // Counted the way git counts. `components(separatedBy:)` returns an empty trailing
            // piece after the final newline, and since practically every text file ends in one,
            // every untracked file used to read one addition too many.
            let lineCount = (try? String(contentsOfFile: full, encoding: .utf8))
                .map(countLines) ?? 0
            byPath[path] = ChangedFile(
                path: path, change: .untracked, additions: lineCount, deletions: 0,
                isBinary: lineCount == 0 && FileManager.default.fileExists(atPath: full)
            )
        }

        return byPath.values.sorted { $0.path < $1.path }
    }

    /// `diff --name-status -z` records: a status field, then one path, except for `R`/`C` where
    /// the similarity score is glued to the status (`R100`) and TWO paths follow, old then new.
    static func parseNameStatus(_ data: Data) -> [String: (ChangedFile.Change, String?)] {
        var changes: [String: (ChangedFile.Change, String?)] = [:]
        var records = nulRecords(data)[...]

        while let status = records.popFirst() {
            guard let code = String(decoding: status.prefix(1), as: UTF8.self).first else { continue }
            if code == "R" || code == "C" {
                guard let old = records.popFirst(), let new = records.popFirst() else { break }
                changes[String(decoding: new, as: UTF8.self)] = (
                    code == "R" ? .renamed : .copied, String(decoding: old, as: UTF8.self)
                )
            } else {
                guard let path = records.popFirst() else { break }
                changes[String(decoding: path, as: UTF8.self)] =
                    (ChangedFile.Change(rawValue: String(code)) ?? .modified, nil)
            }
        }
        return changes
    }

    /// `diff --numstat -z` records: `additions TAB deletions TAB path`, except for a rename or
    /// copy where the path field is empty and the old and new paths follow as their own records.
    static func parseNumstat(
        _ data: Data,
        changes: [String: (ChangedFile.Change, String?)]
    ) -> [String: ChangedFile] {
        var files: [String: ChangedFile] = [:]
        var records = nulRecords(data)[...]

        while let record = records.popFirst() {
            // Only the first two tabs are separators. Any further tab belongs to the path.
            let fields = split(record, on: 0x09, limit: 2)
            guard fields.count == 3 else { continue }

            let additions = String(decoding: fields[0], as: UTF8.self)
            let deletions = String(decoding: fields[1], as: UTF8.self)

            var path = String(decoding: fields[2], as: UTF8.self)
            var oldPath: String?
            if fields[2].isEmpty {
                guard let old = records.popFirst(), let new = records.popFirst() else { break }
                oldPath = String(decoding: old, as: UTF8.self)
                path = String(decoding: new, as: UTF8.self)
            }

            let recorded = changes[path]
            files[path] = ChangedFile(
                path: path,
                oldPath: recorded?.1 ?? oldPath,
                change: recorded?.0 ?? (oldPath == nil ? .modified : .renamed),
                additions: Int(additions) ?? 0,
                deletions: Int(deletions) ?? 0,
                isBinary: additions == "-"
            )
        }
        return files
    }

    /// The NUL-terminated records of a `-z` stream, with the trailing empty record dropped.
    static func nulRecords(_ data: Data) -> [Data] {
        var records: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0 {
            records.append(data[start..<index])
            start = data.index(after: index)
        }
        if start < data.endIndex { records.append(data[start...]) }
        return records
    }

    /// Splits on the first `limit` occurrences of `byte`, leaving the remainder intact.
    static func split(_ data: Data, on byte: UInt8, limit: Int) -> [Data] {
        var pieces: [Data] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex, pieces.count < limit {
            if data[index] == byte {
                pieces.append(data[start..<index])
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        pieces.append(data[start...])
        return pieces
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
                ["diff", "--no-index", "--no-color", "--", "/dev/null", file.path], in: worktree
            )
            // --no-index exits 1 whenever there is a difference, which is the normal case here.
            return result.stdout
        }
        let mergeBase = try await mergeBase(base, in: worktree)
        return try await check(
            ["diff", "--no-color", "-M", mergeBase, "--", file.path], in: worktree
        ).stdout
    }

    public static func hasUncommittedChanges(worktree: String) async throws -> Bool {
        !(try await check(["status", "--porcelain"], in: worktree).trimmed.isEmpty)
    }

    /// Commits on HEAD that `base` does not have. Throws rather than answering 0 when git cannot
    /// resolve the base, because 0 reads as "this branch is in sync".
    public static func commitsAhead(worktree: String, base: String) async throws -> Int {
        try validate(ref: base, label: "base branch")
        let result = try await check(["rev-list", "--count", "\(base)..HEAD", "--"], in: worktree)
        guard let count = Int(result.trimmed) else {
            throw error(["rev-list", "--count", "\(base)..HEAD"], 0, "unreadable count '\(result.trimmed)'", "")
        }
        return count
    }

    // MARK: - Safety

    /// Everything archiving this workspace would destroy, gathered before anything is removed.
    ///
    /// `unpushedCommits` deliberately means "reachable from this branch and from no other ref",
    /// not "ahead of the base branch". A commit that also lives on a remote, on a tag or on
    /// another branch survives deleting this one, and refusing to archive over it would be
    /// noise. A commit nothing else points at does not survive.
    public static func safetyReport(
        worktree: String,
        branch: String,
        base: String,
        repo: String
    ) async throws -> WorkspaceSafetyReport {
        try validate(branch: branch)

        var report = WorkspaceSafetyReport()

        if FileManager.default.fileExists(atPath: worktree), await isRepository(worktree) {
            let status = try await checkRaw(["status", "--porcelain", "-z"], in: worktree)
            (report.hasUncommittedChanges, report.untrackedFiles) = parseStatus(status.stdout)
            report.modifiedIgnoredFiles = try await divergentIgnoredFiles(worktree: worktree, repo: repo)
            report.detachedCommits = try await detachedCommitCount(worktree: worktree, repo: repo)
        }

        guard await branchExists(branch, in: repo) else { return report }

        let refs = try await check(
            ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"],
            in: repo
        ).lines
        // Feeding the other refs in on stdin rather than as arguments, because a repository with
        // thousands of tags would otherwise blow past the argument limit.
        let negated = refs
            .filter { $0 != "refs/heads/\(branch)" }
            .map { "^\($0)" }
            .joined(separator: "\n")
        let unique = try await check(
            ["rev-list", "--count", "--stdin", "refs/heads/\(branch)"],
            in: repo,
            stdin: negated.isEmpty ? "\n" : negated + "\n"
        )
        report.unpushedCommits = Int(unique.trimmed) ?? 0

        if (try? validate(ref: base, label: "base branch")) != nil {
            let merged = try await run(
                ["merge-base", "--is-ancestor", "refs/heads/\(branch)", base], in: repo
            )
            report.isBranchMerged = merged.ok
        }

        return report
    }

    /// `status --porcelain -z` records: `XY path`, and for a rename or copy the new path is
    /// followed by a second record holding the old path.
    static func parseStatus(_ data: Data) -> (dirty: Bool, untracked: [String]) {
        var dirty = false
        var untracked: [String] = []
        var records = nulRecords(data)[...]

        while let record = records.popFirst() {
            guard record.count > 3 else { continue }
            let code = String(decoding: record.prefix(2), as: UTF8.self)
            let path = String(decoding: record.dropFirst(3), as: UTF8.self)
            if code == "??" {
                untracked.append(path)
            } else {
                dirty = true
                if code.contains("R") || code.contains("C") { _ = records.popFirst() }
            }
        }
        return (dirty, untracked)
    }

    /// Ignored files in the worktree that the main checkout does not have, or has differently.
    ///
    /// Only ignored files are considered, because tracked and untracked ones are already covered.
    /// An ignored file that matches the main checkout byte for byte is not a loss: Bloom copied it
    /// there and the original is still where it came from.
    static func divergentIgnoredFiles(worktree: String, repo: String) async throws -> [String] {
        let ignored = try await checkRaw(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], in: worktree
        )

        var divergent: [String] = []
        for record in nulRecords(ignored.stdout) {
            let path = String(decoding: record, as: UTF8.self)
            guard !path.isEmpty else { continue }

            let here = (worktree as NSString).appendingPathComponent(path)
            let there = (repo as NSString).appendingPathComponent(path)

            guard let mine = FileManager.default.contents(atPath: here) else { continue }
            guard let theirs = FileManager.default.contents(atPath: there) else {
                // Exists only in the worktree, so removing the worktree is the end of it.
                divergent.append(path)
                continue
            }
            if mine != theirs { divergent.append(path) }
        }
        return divergent.sorted()
    }

    /// Commits reachable from the worktree's own HEAD and from no ref anywhere.
    ///
    /// Zero unless HEAD is detached, which is what happens when an agent runs `git checkout` in
    /// its worktree. Those commits are held only by the per-worktree reflog, which
    /// `git worktree remove` deletes.
    static func detachedCommitCount(worktree: String, repo: String) async throws -> Int {
        let head = try await run(["symbolic-ref", "--quiet", "HEAD"], in: worktree)
        guard !head.ok else { return 0 }

        let refs = try await check(
            ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"],
            in: repo
        ).lines
        let negated = refs.map { "^\($0)" }.joined(separator: "\n")
        let unique = try await run(
            ["rev-list", "--count", "--stdin", "HEAD"],
            in: worktree,
            stdin: negated.isEmpty ? "\n" : negated + "\n"
        )
        guard unique.ok else { return 0 }
        return Int(unique.trimmed) ?? 0
    }

    /// Lines the way `git diff --numstat` counts them: a trailing newline terminates the last
    /// line rather than starting an empty one.
    static func countLines(_ contents: String) -> Int {
        guard !contents.isEmpty else { return 0 }
        var count = contents.reduce(into: 0) { total, character in
            if character == "\n" { total += 1 }
        }
        // A file whose last line has no newline still has that line.
        if contents.hasSuffix("\n") == false { count += 1 }
        return count
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

        var parts = Array(kept.prefix(maxWords))

        // A file path is usually the most distinguishing thing in a prompt, and it is exactly
        // what falls off the end of the word budget. Without this, "add a docblock to Invoice.php"
        // and "... to Contact.php" produce the same branch, and the collision suffix (-2, -3)
        // leaves a sidebar full of names that say nothing about which is which.
        if let token = distinguishingToken(from: firstLine), !parts.contains(token) {
            parts.append(token)
        }

        return String(parts.joined(separator: "-").prefix(60))
    }

    /// The basename of the first path-like token in a line, lowercased and hyphenated.
    static func distinguishingToken(from line: String) -> String? {
        let separators = CharacterSet(charactersIn: " \t,;()[]{}\"'`")
        for token in line.components(separatedBy: separators) where !token.isEmpty {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            let base = (trimmed as NSString).lastPathComponent
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension

            // Either an actual path, or something that really looks like a filename. A bare
            // sentence ending in a full stop must not qualify.
            let looksLikePath = trimmed.contains("/")
            let looksLikeFile = !ext.isEmpty && ext.count <= 5
                && ext.allSatisfy(\.isLetter) && stem.count >= 3
            guard looksLikePath || looksLikeFile else { continue }

            let cleaned = stem
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            if cleaned.count >= 2 { return cleaned }
        }
        return nil
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

/// Thread-safe accumulator for `runRaw`, which keeps stdout as bytes.
private final class ByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    /// One count per stream, so a caller can wait until both have genuinely finished.
    private let eof = DispatchGroup()

    init() {
        eof.enter()
        eof.enter()
    }

    func appendOut(_ data: Data) {
        lock.lock(); stdout.append(data); lock.unlock()
    }

    func appendErr(_ data: Data) {
        lock.lock(); stderr.append(data); lock.unlock()
    }

    func finishOut() { eof.leave() }
    func finishErr() { eof.leave() }

    func waitForEOF() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eof.notify(queue: .global()) { continuation.resume() }
        }
    }

    var out: Data {
        lock.lock(); defer { lock.unlock() }
        return stdout
    }

    var err: Data {
        lock.lock(); defer { lock.unlock() }
        return stderr
    }
}
