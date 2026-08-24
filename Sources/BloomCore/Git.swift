import Foundation
import Synchronization

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

/// Running git, and the facts every other part of `Git` asks it for.
///
/// The subjects that grew their own files are next to this one: `Git+Worktrees.swift`,
/// `Git+Diffs.swift`, `Git+Safety.swift`, `Git+Branches.swift`, `Git+Naming.swift` and
/// `Git+Repository.swift`. What stays here is what they all reach for. The four ways of
/// running a process, because every call goes through one of them and the environment they set
/// is not worth having two copies of. The ref validation, because a name that git would read as
/// an option is a danger at every call site rather than in one subject. The repository facts,
/// because `baseline` alone is asked for by diffs, by commits and by the safety report. And the
/// two byte-record helpers, which the diff parsers and the status parser share.
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
        // The same gate `Shell.run` opens with, for the same caller: the refresh loop's deadline
        // cancels a queue of these at once, and spawning git for a caller that has already given
        // up would fork it and terminate it in the same breath.
        try Task.checkCancellation()

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

        let collector = PipeCollector()
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

    // MARK: - Byte records

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
}
