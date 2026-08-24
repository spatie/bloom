import Foundation

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
