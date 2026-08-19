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

/// What this worktree is holding that GitHub has not been told about.
///
/// The question a pull request strip has to answer alongside GitHub's own: is the branch on the
/// server still the work that is on this disk. Every state GitHub reports ("checks passed",
/// "ready to merge") is about a commit that was pushed, and the moment anything is edited or
/// committed afterwards those states describe something that no longer exists here.
///
/// Deliberately NOT `WorkspaceSafetyReport`. That one asks "what would deleting this worktree
/// destroy", and its `unpushedCommits` means "reachable from this branch and from no other ref",
/// which counts a commit as safe when a tag or another local branch happens to point at it. That
/// is the right question before an archive and the wrong one here: a commit sitting on a local
/// tag is still a commit GitHub does not have. It is also expensive, walking every ref in the
/// repository and byte-comparing every ignored file, which is not something to run beside a poll.
public struct LocalWork: Sendable, Hashable {
    /// Tracked files with changes that are not committed, staged or not.
    public var modifiedFiles: Int
    /// Files git has never been told about. Counted apart from the ones above because they are
    /// the half a reader is most likely to have meant to leave lying around.
    public var untrackedFiles: Int
    /// Commits on this branch that its upstream does not have. Zero when there is no upstream,
    /// which `hasUpstream` is what distinguishes.
    public var unpushedCommits: Int
    /// Whether this branch is tracking anything at all. False means it has never been pushed, so
    /// there is no count to give: everything on it is unpushed by definition.
    public var hasUpstream: Bool

    public init(
        modifiedFiles: Int = 0,
        untrackedFiles: Int = 0,
        unpushedCommits: Int = 0,
        hasUpstream: Bool = true
    ) {
        self.modifiedFiles = modifiedFiles
        self.untrackedFiles = untrackedFiles
        self.unpushedCommits = unpushedCommits
        self.hasUpstream = hasUpstream
    }

    /// Anything in the worktree that a push alone would not carry.
    public var hasUncommitted: Bool { modifiedFiles > 0 || untrackedFiles > 0 }

    /// Committed work the remote does not have.
    ///
    /// False on a branch with no upstream, and that is deliberate rather than an oversight: with
    /// nothing to compare against there is no count, and guessing one would be worse than saying
    /// nothing. The strip only ever asks this about a branch that already has a pull request, and
    /// a branch with a pull request has an upstream.
    public var hasUnpushed: Bool { hasUpstream && unpushedCommits > 0 }

    /// Whether GitHub's idea of this branch is out of date.
    public var isAhead: Bool { hasUncommitted || hasUnpushed }
}

public struct WorktreeEntry: Sendable, Hashable {
    public var path: String
    public var head: String
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
}

/// Which ignored paths are worth naming when a worktree is about to be deleted.
///
/// The check they feed exists for a real reason: `git status --porcelain` does not list ignored
/// files and `git worktree remove` deletes them without a word. Bloom copies `.env*` into every
/// worktree, which makes an edited `.env` both the likeliest file to be destroyed and the one
/// nobody thinks to check.
///
/// Naming every divergent ignored file turned that into a confirmation listing 981 paths, nearly
/// all of them `node_modules/...`. A list nobody can read is not a safety check; it buries the
/// one line that mattered under the noise.
///
/// The rule that separates the two is reproducibility. `node_modules` is ignored precisely
/// because a package manager rebuilds it from a lockfile that IS in git, so losing it costs an
/// install rather than a piece of work. Nothing rebuilds `.env`. A path is therefore left out
/// when it lies inside a directory whose entire job is to hold something a tool regenerates, and
/// named otherwise.
///
/// Two things worth being explicit about:
///
/// - This is a list of names, not a clever test. Nothing can ask the filesystem whether a file
///   could be rebuilt, so the honest implementation is a curated set with a bias: a name goes in
///   only when a hand-written file living under it would be surprising. Names that are sometimes
///   build output and sometimes not (`out`, `tmp`, `data`, `.idea`) are deliberately absent,
///   because leaving one out costs a line of noise and putting one in costs somebody their work.
/// - `.bloom` is ours. The app creates it to hold prompt attachments, so listing it as work at
///   risk is Bloom warning the user about Bloom.
public enum ReproduciblePaths {
    /// Directory names a package manager, build tool or cache owns end to end.
    ///
    /// Matched against every component of the path, because a monorepo's `apps/web/node_modules`
    /// is as reproducible as a root one.
    public static let directories: Set<String> = [
        // Ours, so never the user's work to lose.
        ".bloom",
        // Dependency installs, each rebuilt from a lockfile or manifest that is in git.
        "node_modules", "bower_components", "jspm_packages", ".pnpm", ".pnpm-store", ".yarn",
        "vendor", "Pods", "Carthage", ".venv", "venv", "virtualenv", ".tox", ".bundle",
        ".cargo", ".gradle", ".m2", ".stack-work", ".pub-cache", ".dart_tool", "_build",
        // Build output.
        "dist", "build", ".build", "target", ".next", ".nuxt", ".output", ".svelte-kit",
        ".astro", ".docusaurus", ".vercel", ".netlify", "DerivedData", ".swiftpm",
        // Caches and coverage.
        ".cache", ".turbo", ".parcel-cache", ".vite", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".ruff_cache", ".phpunit.cache", ".sass-cache", ".nyc_output",
        ".terraform", ".serverless", "coverage",
    ]

    /// Whole file names nobody writes by hand.
    public static let files: Set<String> = [
        ".DS_Store", "Thumbs.db", ".eslintcache", ".phpunit.result.cache",
    ]

    /// Suffixes of compiled artefacts, regenerated by whatever reads them.
    public static let suffixes = [".pyc", ".pyo", ".class"]

    /// Whether losing this path costs an install rather than a piece of work.
    ///
    /// - Parameter path: repository-relative, as git prints it. A trailing slash means git
    ///   collapsed a wholly ignored directory into one entry, which is the case this exists for.
    public static func canBeRebuilt(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last.map(String.init) else { return false }

        if components.contains(where: { directories.contains(String($0)) }) { return true }
        if files.contains(last) { return true }
        return suffixes.contains { last.hasSuffix($0) }
    }
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
    /// Ignored paths that differ from the main checkout, or exist only here, minus everything a
    /// tool can rebuild. A trailing slash means a whole directory, named once.
    ///
    /// `git status --porcelain` does not list ignored files and `git worktree remove` deletes them
    /// without a word, so these were invisible. Bloom copies `.env*` into every worktree, which
    /// makes an edited `.env` both the likeliest file to be destroyed and the one nobody would
    /// think to check. What is NOT here, and why, is `ReproduciblePaths`.
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
            // A trailing slash means the entry is a whole directory, named once, so the noun has
            // to allow for one. Everything a package manager could put back is already gone from
            // this list, which is what makes naming the rest worth the reader's time.
            let folders = modifiedIgnoredFiles.contains { $0.hasSuffix("/") }
            let one = modifiedIgnoredFiles.count == 1
            let noun = switch (one, folders) {
            case (true, true): "ignored folder"
            case (true, false): "ignored file"
            case (false, true): "ignored files and folders"
            case (false, false): "ignored files"
            }
            losses.append(
                "\(modifiedIgnoredFiles.count) \(noun) that \(one ? "differs" : "differ") "
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
    /// - Parameter timeout: nil for the local calls, which answer in milliseconds and have no
    ///   business being killed halfway through. Anything that touches the network passes one:
    ///   `GIT_TERMINAL_PROMPT=0` stops git asking for credentials, but nothing stops a TCP
    ///   connection to an unreachable host from hanging for minutes behind a spinner.
    static func run(
        _ arguments: [String],
        in directory: String,
        stdin: String? = nil,
        timeout: Duration? = nil
    ) async throws -> ShellResult {
        try await Shell.run("git", arguments, cwd: directory, env: [
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ], stdin: stdin, timeout: timeout)
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

    /// Whether `ancestor` is reachable from `descendant`. A commit is its own ancestor, as git
    /// counts it. False when either ref does not resolve, because the question was unanswerable
    /// and every caller reads a no as "leave it alone".
    public static func isAncestor(
        _ ancestor: String, of descendant: String, in path: String
    ) async -> Bool {
        guard (try? validate(ref: ancestor, label: "revision")) != nil,
              (try? validate(ref: descendant, label: "revision")) != nil
        else { return false }
        let result = try? await run(
            ["merge-base", "--is-ancestor", ancestor, descendant], in: path
        )
        return result?.ok ?? false
    }

    /// Where this worktree left the base branch, in the sense the review tab means it.
    ///
    /// A workspace records its base as a plain branch name, and reading that as the local branch
    /// alone is what produced the bug this exists for. Bloom never moves a repository's local
    /// `main`: that branch is the user's own checkout, they may have commits on it, it may be
    /// dirty, and fast-forwarding it behind their back is not this app's to do. So once a pull
    /// request is squashed and the workspace is continued, the new branch is correctly cut from
    /// `origin/main` while the local `main` is still where it was, and every file that has just
    /// been merged shows up in the diff as though this workspace had written it. It survived
    /// workspace switches and restarts, because the wrong answer was on disk rather than in
    /// memory.
    ///
    /// The fix is to ask both refs and take whichever divergence point is FURTHER ALONG, which is
    /// the one that is a descendant of the other. Not simply the remote one:
    ///
    /// - Continued after a merge, the branch is cut from `origin/main`, so the remote's merge
    ///   base is the newer of the two and the diff narrows to the new work alone.
    /// - With unpushed commits on local `main` and a branch cut from those, the local merge base
    ///   is the newer one, and the user's own unpushed work is correctly not counted as this
    ///   workspace's.
    ///
    /// Nothing is fetched, nothing is moved and nothing is written. A repository with no remote,
    /// a base branch with no upstream, and a base branch that exists only on the remote all go
    /// through the same path and none of them is an error: a candidate that does not resolve is
    /// simply not a candidate. Only a base that resolves nowhere at all throws, exactly as
    /// `mergeBase` already does, because an empty diff reading as "this workspace changed
    /// nothing" is the failure worth being loud about.
    public static func baseline(_ base: String, in worktree: String) async throws -> String {
        try validate(ref: base, label: "base branch")

        let local = try? await mergeBase(base, in: worktree)

        let tracking = "refs/remotes/\(remote)/\(base)"
        guard await revision(of: tracking, in: worktree) != nil,
              let remoteSide = try? await mergeBase(tracking, in: worktree)
        else {
            // No remote-tracking copy, so the local answer is the only answer. Asking for it
            // again rather than giving up lets `mergeBase` throw its own error when the base
            // resolves nowhere.
            if let local { return local }
            return try await mergeBase(base, in: worktree)
        }

        guard let local else { return remoteSide }
        guard local != remoteSide else { return local }
        return await isAncestor(local, of: remoteSide, in: worktree) ? remoteSide : local
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
        let mergeBase = try await baseline(base, in: worktree)

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
        let mergeBase = try await baseline(base, in: worktree)
        return try await check(
            ["diff", "--no-color", "-M", mergeBase, "--", file.path], in: worktree
        ).stdout
    }

    /// What this worktree is holding that the remote has not got, in one `git` call.
    ///
    /// `status --porcelain=v1 -z --branch` answers all of it at once: the first record is a header
    /// reading `## branch...upstream [ahead N, behind M]`, and every record after it is a changed
    /// file. Asking separately would be a `status` plus a `rev-list`, and this runs beside a poll
    /// that already spends three git calls every six seconds.
    ///
    /// The header is the only way to get the ahead count without naming a remote ref by hand.
    /// `@{upstream}` in a `rev-list` fails outright on a branch that has never been pushed, and a
    /// branch that has never been pushed is precisely the case this has to be able to describe.
    public static func localWork(worktree: String) async throws -> LocalWork {
        let status = try await checkRaw(
            ["status", "--porcelain=v1", "-z", "--branch"], in: worktree
        )
        return parseLocalWork(status.stdout)
    }

    /// The records of `status --porcelain=v1 -z --branch`, header first.
    ///
    /// One pass, counting rather than collecting: the strip says how many, never which, and a
    /// worktree mid `npm install` can hold thousands of untracked paths that nothing would read.
    /// A rename or a copy is two records and one file, so its second record is skipped, which is
    /// the same rule `parseStatus` follows before an archive.
    static func parseLocalWork(_ data: Data) -> LocalWork {
        var records = nulRecords(data)[...]
        var work = LocalWork()

        guard let header = records.first,
              String(decoding: header.prefix(2), as: UTF8.self) == "##" else {
            // No header means git answered something this does not understand. Reporting "nothing
            // local" would be a claim, and so would reporting a clean worktree, so the caller gets
            // the empty value and the strip says nothing rather than something wrong.
            return work
        }
        records.removeFirst()

        // `## branch...upstream [ahead 2, behind 1]`, or `## branch` with no upstream at all, or
        // `## HEAD (no branch)` on a detached head.
        let line = String(decoding: header.dropFirst(3), as: UTF8.self)
        work.hasUpstream = line.contains("...")
        if let ahead = line.range(of: "[ahead "),
           let end = line[ahead.upperBound...].firstIndex(where: { $0 == "," || $0 == "]" }) {
            work.unpushedCommits = Int(line[ahead.upperBound..<end]) ?? 0
        }

        while let record = records.popFirst() {
            guard record.count > 3 else { continue }
            let code = String(decoding: record.prefix(2), as: UTF8.self)
            if code == "??" {
                work.untrackedFiles += 1
            } else {
                work.modifiedFiles += 1
                if code.contains("R") || code.contains("C") { _ = records.popFirst() }
            }
        }
        return work
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

        // A directory that is not there holds nothing, so an empty report is the true answer. A
        // directory that IS there and cannot be read as a repository is a different thing
        // entirely: git could not be asked, and every field below would be a zero standing in for
        // an answer nobody has. `isSafeToDiscard` would read that as "nothing at stake" and let
        // the worktree be deleted, so it throws instead, and the caller shows the reason.
        if FileManager.default.fileExists(atPath: worktree) {
            guard await isRepository(worktree) else {
                throw ShellError(
                    command: "git status",
                    status: 128,
                    stderr: "\(worktree) is not a git worktree, so what is in it cannot be checked"
                )
            }
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

    /// Ignored paths in the worktree that the main checkout does not have, or has differently,
    /// with everything a tool can rebuild left out. See `ReproduciblePaths`.
    ///
    /// Only ignored paths are considered, because tracked and untracked ones are already covered.
    /// An ignored file that matches the main checkout byte for byte is not a loss: Bloom copied it
    /// there and the original is still where it came from.
    ///
    /// `--directory` is what makes this cheap enough to run in front of a confirmation. It
    /// collapses a wholly ignored directory into one record with a trailing slash, so a
    /// `node_modules` of forty thousand files costs a single line instead of forty thousand
    /// paths and forty thousand file reads. It is also the level the reproducibility rule wants
    /// to work at: the answer for `node_modules/` is the answer for everything inside it.
    static func divergentIgnoredFiles(worktree: String, repo: String) async throws -> [String] {
        let ignored = try await checkRaw(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
            in: worktree
        )

        var paths: [String] = []
        for record in nulRecords(ignored.stdout) {
            let path = String(decoding: record, as: UTF8.self)
            guard !path.isEmpty, !ReproduciblePaths.canBeRebuilt(path) else { continue }
            paths.append(path)
        }

        // Git lists a directory and, sometimes, a directory nested inside it. Reporting both
        // would name the same loss twice, so only the outermost entry survives: it covers
        // everything the inner one did.
        let directories = paths.filter { $0.hasSuffix("/") }
        let covering = paths.filter { path in
            !directories.contains { $0 != path && path.hasPrefix($0) }
        }

        var divergent: [String] = []
        for path in covering {
            let here = (worktree as NSString).appendingPathComponent(path)
            let there = (repo as NSString).appendingPathComponent(path)
            if path.hasSuffix("/") {
                // Named as one line rather than expanded. "storage/logs/" says what would be
                // lost; its two hundred files say it two hundred times.
                if directoryDiffers(here, there) { divergent.append(path) }
            } else if fileDiffers(here, there) {
                divergent.append(path)
            }
        }
        return divergent.sorted()
    }

    /// Whether two files at the same repository-relative path hold different bytes.
    ///
    /// Size first. Two files of different lengths cannot be equal, and answering from the inode
    /// rather than from the contents is what keeps a directory of large ignored files off the
    /// critical path of a confirmation.
    ///
    /// Every uncertain answer is "differs". A file that exists here and cannot be read is not
    /// evidence that nothing is at stake; it is the absence of evidence, and the version of this
    /// that skipped an unreadable file quietly counted it as safe to destroy. The only case that
    /// returns false without looking is a file that is no longer there at all, which cannot be
    /// destroyed by removing the directory it has already left.
    static func fileDiffers(_ here: String, _ there: String) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: here) else { return false }
        // Exists only in the worktree, so removing the worktree is the end of it.
        guard manager.fileExists(atPath: there) else { return true }

        let mySize = (try? manager.attributesOfItem(atPath: here)[.size] as? Int) ?? nil
        let theirSize = (try? manager.attributesOfItem(atPath: there)[.size] as? Int) ?? nil
        if let mySize, let theirSize, mySize != theirSize { return true }

        guard let mine = manager.contents(atPath: here) else { return true }
        guard let theirs = manager.contents(atPath: there) else { return true }
        return mine != theirs
    }

    /// Whether a wholly ignored directory holds anything the main checkout does not.
    ///
    /// Bounded on purpose. An unknown ignored directory big enough to make this expensive is
    /// already something whose contents nobody is going to read out of a confirmation, and a
    /// walk that could run for a minute is exactly what this rewrite exists to remove. Past the
    /// bound the answer is "it differs", because the alternative is telling somebody there is
    /// nothing at stake on the strength of a check that gave up.
    static func directoryDiffers(_ here: String, _ there: String, limit: Int = 2_000) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: here) else { return false }
        guard manager.fileExists(atPath: there) else { return true }

        guard let walk = manager.enumerator(atPath: here) else { return true }
        var seen = 0
        for case let relative as String in walk {
            var isDirectory: ObjCBool = false
            let file = (here as NSString).appendingPathComponent(relative)
            guard manager.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }

            seen += 1
            if seen > limit { return true }
            if fileDiffers(file, (there as NSString).appendingPathComponent(relative)) { return true }
        }
        return false
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
    ///
    /// Public because the transcript counts lines too, for the "42 lines" a Write chip shows and
    /// for a turn's own rollup of what it changed. Those numbers sit a few points from the
    /// inspector's, which are git's, so they have to be counted the same way.
    public static func countLines(_ contents: String) -> Int {
        guard !contents.isEmpty else { return 0 }
        var count = contents.reduce(into: 0) { total, character in
            if character == "\n" { total += 1 }
        }
        // A file whose last line has no newline still has that line.
        if contents.hasSuffix("\n") == false { count += 1 }
        return count
    }

    // MARK: - Renaming a branch

    /// `git branch -m`, refusing anything git would read as an option.
    ///
    /// Safe to run against a branch that is checked out in a worktree: git moves the ref and
    /// rewrites the worktree's HEAD to point at the new name, and nothing on disk moves. The
    /// worktree's directory keeps whatever name it was created with, which is deliberate. A
    /// worktree's path is recorded in three places at once and is the working directory of every
    /// shell, agent and dev server the workspace has open, so it is never moved.
    public static func renameBranch(_ old: String, to new: String, in directory: String) async throws {
        try validate(branch: old)
        try validate(branch: new)
        try await check(["branch", "-m", "--", old, new], in: directory)
    }

    // MARK: - Cutting a branch from an updated base

    /// The remote Bloom talks to. Spelled once here rather than threaded through every call: the
    /// rest of the app already hardcodes it (`GitHub.push`, `GitHub.deleteRemoteBranch`), and a
    /// second, configurable idea of which remote is the real one would only be able to disagree
    /// with those.
    public static let remote = "origin"

    /// Updates one branch's remote-tracking ref, and says whether it worked.
    ///
    /// An explicit refspec rather than `git fetch origin main`. The bare form leaves whether
    /// `refs/remotes/origin/main` is written up to the remote's configured fetch refspec, which a
    /// single-branch clone or a hand-edited config can perfectly well not have. Naming the
    /// destination means the ref this asks for is the ref that gets written.
    ///
    /// Never throws. Being offline is an ordinary thing rather than an error, and every caller
    /// here has somewhere to fall back to.
    public static func fetch(
        _ branch: String, in directory: String, timeout: Duration = .seconds(20)
    ) async -> Bool {
        guard isValidBranchName(branch) else { return false }
        let refspec = "+refs/heads/\(branch):refs/remotes/\(remote)/\(branch)"
        let result = try? await run(
            ["fetch", "--no-tags", "--", remote, refspec], in: directory, timeout: timeout
        )
        return result?.ok ?? false
    }

    /// The commit a ref points at, or nil when it does not resolve.
    public static func revision(of ref: String, in directory: String) async -> String? {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains("\0") else { return nil }
        guard let result = try? await run(["rev-parse", "--verify", "\(ref)^{commit}"], in: directory),
              result.ok, !result.trimmed.isEmpty else { return nil }
        return result.trimmed
    }

    /// Where a new branch should start, having tried to make the base current first.
    ///
    /// Three answers, in order of how much they are worth, and the caller is told which one it
    /// got because two of them mean the new branch is missing work that is already on the base:
    ///
    /// 1. Fetch worked: `origin/<base>` as the server has it right now. The point of the exercise.
    /// 2. Fetch failed: whatever `origin/<base>` was at the last successful fetch. Offline, or a
    ///    remote that needs credentials nobody has given.
    /// 3. No remote-tracking ref at all: the local `<base>`. A repository with no remote, which
    ///    Bloom supports everywhere else and supports here.
    ///
    /// Throws only when none of the three resolve, which means the base branch does not exist in
    /// any form. Guessing a revision at that point would be the one mistake worth failing over.
    public static func baseRevision(
        branch: String, in directory: String
    ) async throws -> (revision: String, base: ContinuationBase) {
        try validate(branch: branch)
        let fetched = await fetch(branch, in: directory)

        if let revision = await revision(of: "refs/remotes/\(remote)/\(branch)", in: directory) {
            return (revision, fetched ? .fetched : .cachedRemote)
        }
        if let revision = await revision(of: "refs/heads/\(branch)", in: directory) {
            return (revision, .localBranch)
        }
        throw ShellError(
            command: "git rev-parse \(branch)",
            status: 1,
            stderr: "Bloom could not find \(branch) here, on \(remote) or on this disk."
        )
    }

    /// Cuts a branch at a revision and checks it out, in a worktree that is on another branch.
    ///
    /// Uncommitted work comes along: `git checkout -b` carries the working tree over as it stands.
    /// What it does NOT do is carry it over destructively. Where a file differs between the two
    /// revisions and has been edited, git refuses the checkout and says so, and this surfaces
    /// that refusal rather than reaching for `--force`, which would delete the edit.
    public static func checkoutNewBranch(
        _ branch: String, at revision: String, in directory: String
    ) async throws {
        try validate(branch: branch)
        try validate(ref: revision, label: "revision")
        // No `--` before the revision: that separator marks the start of PATHS, and git would
        // read the commit as a pathspec and fail. `validate(ref:)` above is what keeps a
        // revision beginning with a dash from being read as an option instead.
        try await check(["checkout", "-b", branch, revision], in: directory)
    }

    /// How many commits `head` has that `base` does not.
    ///
    /// Answers 0 rather than throwing when the range cannot be resolved. Every caller of this is
    /// deciding whether something is safe, and "git could not tell me" has to be handled by the
    /// caller as its own thing rather than arriving disguised as a number.
    public static func commitsAhead(base: String, head: String = "HEAD", in directory: String) async throws -> Int {
        try validate(ref: base, label: "base branch")
        try validate(ref: head, label: "revision")
        let result = try await run(["rev-list", "--count", "\(base)..\(head)"], in: directory)
        guard result.ok else { return 0 }
        return Int(result.trimmed) ?? 0
    }

    /// The tracking branch configured for `branch`, or nil when there is none.
    public static func upstream(of branch: String, in directory: String) async throws -> String? {
        try validate(branch: branch)
        let result = try await run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "\(branch)@{upstream}"],
            in: directory
        )
        guard result.ok, !result.trimmed.isEmpty else { return nil }
        return result.trimmed
    }

    /// Whether any remote-tracking ref carries this branch's name.
    ///
    /// Local knowledge only, no network. It catches the branch that was pushed without
    /// `--set-upstream`, which leaves no upstream to find but still leaves a branch on the remote
    /// that a local rename would strand.
    public static func hasRemoteCounterpart(_ branch: String, in directory: String) async -> Bool {
        guard isValidBranchName(branch) else { return false }
        guard let result = try? await run(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes"], in: directory
        ), result.ok else { return false }

        return result.lines.contains { ref in
            // `origin/feature/x` for branch `feature/x`. Suffix matching rather than a glob,
            // because a branch name may itself contain slashes and a remote may be called
            // anything at all.
            ref.hasSuffix("/" + branch)
        }
    }

    /// Whether a rebase, merge, cherry-pick, revert or bisect is half finished here.
    ///
    /// `git branch -m` on a branch in this state is how a half-applied rebase loses the ref it was
    /// going to return to.
    public static func hasOperationInProgress(in directory: String) async -> Bool {
        let markers = [
            "rebase-merge", "rebase-apply", "MERGE_HEAD",
            "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
        ]
        for marker in markers {
            guard let result = try? await run(["rev-parse", "--git-path", marker], in: directory),
                  result.ok else { continue }
            let path = result.trimmed
            guard !path.isEmpty else { continue }
            let absolute = path.hasPrefix("/")
                ? path
                : (directory as NSString).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: absolute) { return true }
        }
        return false
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

// MARK: - Starting a repository

/// Everything needed to turn a folder that is not a repository into one that a worktree can be
/// cut from. Kept apart from the rest of `Git` because it is the only place in the app that
/// writes to a folder the user chose rather than to a worktree Bloom made.
public extension Git {
    /// Runs `git init` and returns the branch it left HEAD pointing at.
    ///
    /// The branch name is the user's `init.defaultBranch` when they have set one, and `main`
    /// otherwise. Passing `-b main` unconditionally would override a deliberate setting, and
    /// passing nothing at all leaves anybody without the setting on `master`.
    @discardableResult
    static func initRepository(at path: String) async throws -> String {
        let configured = try? await run(["config", "--get", "init.defaultBranch"], in: path)
        let preference = (configured?.ok ?? false) ? configured?.trimmed ?? "" : ""
        let arguments = preference.isEmpty ? ["init", "-b", "main"] : ["init"]
        try await check(arguments, in: path)
        // `rev-parse --abbrev-ref HEAD` says "HEAD" before the first commit. `symbolic-ref` reads
        // the ref that HEAD points at, which exists from the moment init finishes.
        return try await check(["symbolic-ref", "--short", "HEAD"], in: path).trimmed
    }

    /// Whether HEAD resolves. False in a repository that has been initialised and never committed,
    /// which is the state `git worktree add` cannot start a branch from.
    static func hasCommits(in path: String) async -> Bool {
        let result = try? await run(["rev-parse", "--verify", "--quiet", "HEAD"], in: path)
        return result?.ok ?? false
    }

    /// The name and address git would put on a commit made here. Either can be missing, and a
    /// commit with neither fails with a page of advice, so this is asked before anything is done.
    static func commitIdentity(in path: String) async -> (name: String?, email: String?) {
        func value(_ key: String) async -> String? {
            guard let result = try? await run(["config", "--get", key], in: path), result.ok else {
                return nil
            }
            let trimmed = result.trimmed
            return trimmed.isEmpty ? nil : trimmed
        }
        return await (value("user.name"), value("user.email"))
    }

    /// The repository this folder sits inside, if any, found by walking up rather than by asking
    /// git.
    ///
    /// git is asked first everywhere else, and `rev-parse --is-inside-work-tree` already answers
    /// yes for a subdirectory of a repository. This exists for what that misses: a folder inside
    /// somebody's `.git`, a ceiling set in the environment, or a repository whose work tree git
    /// declines to claim. Initialising inside any of them produces a repository nested in another,
    /// so it is worth a second, dumber check.
    static func enclosingRepositoryRoot(of path: String) -> String? {
        let manager = FileManager.default
        var current = URL(fileURLWithPath: FolderPath.normalize(path)).deletingLastPathComponent()
        while current.path != "/" && !current.path.isEmpty {
            if manager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    /// Whether the repository's own ignore rules already cover this path. Asked so Bloom only
    /// writes a `.gitignore` line for a file that would otherwise really be committed.
    static func isIgnored(_ relativePath: String, in repo: String) async -> Bool {
        let result = try? await run(["check-ignore", "--quiet", "--", relativePath], in: repo)
        return result?.ok ?? false
    }

    static func stageAll(in repo: String) async throws {
        try await check(["add", "--all", "--", "."], in: repo)
    }

    /// The paths currently in the index, one per entry. Used to count what a first commit will
    /// contain and to prove that nothing that was meant to be excluded ended up in it.
    static func stagedPaths(in repo: String) async throws -> [String] {
        let output = try await checkRaw(["diff", "--cached", "--name-only", "-z", "--"], in: repo)
        return String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\0")
            .map(String.init)
    }

    static func unstage(_ paths: [String], in repo: String) async throws {
        guard !paths.isEmpty else { return }
        try await check(["rm", "--cached", "--quiet", "-r", "--"] + paths, in: repo)
    }

    /// Makes the commit and says whether it had to be made without a signature.
    ///
    /// A machine configured to sign every commit signs this one too. When the signing itself
    /// fails, which it does whenever the key needs a passphrase there is no terminal to type into,
    /// the commit is retried unsigned rather than abandoned: the alternative is a repository with
    /// no commits, which is the one state that cannot be used. The caller is told, so the dialog
    /// can say it happened instead of leaving the user to notice later.
    static func commit(
        message: String, in repo: String, allowEmpty: Bool
    ) async throws -> Bool {
        var arguments = ["commit", "--message", message]
        if allowEmpty { arguments.append("--allow-empty") }

        let result = try await run(arguments, in: repo)
        if result.ok { return false }

        let output = result.stderr + result.stdout
        guard indicatesSigningFailure(output) else {
            throw error(arguments, result.status, result.stderr, result.stdout)
        }

        try await check(["-c", "commit.gpgsign=false"] + arguments, in: repo)
        return true
    }

    /// git reports a key it could not use in several different sentences, none of which has an
    /// exit code of its own.
    static func indicatesSigningFailure(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("gpg failed to sign")
            || lowered.contains("failed to write commit object")
            || lowered.contains("failed to fill whole buffer")
            || lowered.contains("signing failed")
            || lowered.contains("no secret key")
    }

    /// Adds a remote. The URL travels after `--` so a value that begins with a dash cannot be read
    /// as an option, the same rule every other ref and name in this file follows.
    static func addRemote(_ name: String, url: String, in repo: String) async throws {
        try await check(["remote", "add", "--", name, url], in: repo)
    }

    static func remoteURL(_ name: String, in repo: String) async -> String? {
        guard let result = try? await run(["remote", "get-url", "--", name], in: repo),
              result.ok else { return nil }
        let trimmed = result.trimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}
