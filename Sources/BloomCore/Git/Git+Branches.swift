import Foundation

/// Moving a branch's name, and cutting a new branch from a base that has moved on.
///
/// The two belong together because both are ref surgery on a worktree somebody is sitting in,
/// and both are written to leave what is on disk alone: a rename moves the ref and never the
/// directory, and a checkout carries uncommitted work across rather than forcing over it.
///
/// The thread through the second half is that "the base branch" is three different refs
/// depending on what this clone has: the remote-tracking copy after a fetch, the same copy
/// without one because the network was not there, and a local branch in a repository with no
/// remote at all. `baseRevision` returns which of the three it used, so what the user is told
/// afterwards is what actually happened.
extension Git {
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
        // `rev-parse` takes `--git-path` as many times as it is given and prints one line per
        // marker, in order, so six processes are one. It fails only for a directory that is not a
        // repository, where all six failed anyway.
        let arguments = ["rev-parse"] + markers.flatMap { ["--git-path", $0] }
        guard let result = try? await run(arguments, in: directory), result.ok else { return false }

        return result.lines.contains { line in
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return false }
            let absolute = path.hasPrefix("/")
                ? path
                : (directory as NSString).appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: absolute)
        }
    }
}
