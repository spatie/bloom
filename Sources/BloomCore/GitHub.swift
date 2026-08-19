import Foundation

/// A normalized check record keeps the UI independent of GitHub's two rollup shapes.
public struct CheckRun: Sendable, Hashable, Identifiable {
    public let name: String
    public let status: String
    public let conclusion: String?
    public let detailsURL: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public let workflowName: String?
    private let required: Bool?

    public var id: String {
        [workflowName, name, detailsURL].compactMap { $0 }.joined(separator: ":")
    }

    /// Unknown requiredness is treated conservatively so older gh versions do not hide failures.
    public var isRequired: Bool { required ?? true }

    public init(
        name: String,
        status: String,
        conclusion: String? = nil,
        detailsURL: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        workflowName: String? = nil,
        isRequired: Bool? = nil
    ) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.detailsURL = detailsURL
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.workflowName = workflowName
        self.required = isRequired
    }
}

/// What merging did, and what it could not finish afterwards.
///
/// Merging is two things happening in order: a network call that lands the pull request, and some
/// tidying up that does not. They fail separately, so they are reported separately. Anything this
/// value describes has already merged, which is why there is no `merged` flag on it: a merge that
/// did not happen throws instead.
public struct MergeOutcome: Sendable, Equatable {
    /// What was left behind, when something was.
    public enum Leftover: Sendable, Equatable {
        /// The branch is still on GitHub.
        case remoteBranch(String)
        /// gh merged and then failed to tidy up the local repository. See `GitHub.merge`.
        case localTidyUp
    }

    public var leftover: Leftover?

    public init(leftover: Leftover? = nil) {
        self.leftover = leftover
    }
}

public extension MergeOutcome.Leftover {
    /// What to put in front of a person, given that the merge itself worked.
    ///
    /// It says the merge succeeded first, because that is the part they were waiting for, and
    /// describes the rest as a leftover rather than as a failure. No command line and no git
    /// output: neither is a sentence, and the state they describe is visible on GitHub.
    var sentence: String {
        switch self {
        case .remoteBranch(let branch):
            """
            The pull request is merged. The branch \(branch) could not be deleted on GitHub, so it \
            is still there. The worktree on this machine is untouched.
            """
        case .localTidyUp:
            """
            The pull request is merged. The GitHub CLI could not tidy up afterwards, because a \
            worktree cannot check out a branch that your main copy already has. Nothing on this \
            machine was changed.
            """
        }
    }
}

/// GitHub failures retain command context or invalid output without exposing unbounded output.
public struct GitHubError: Error, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

private struct PullRequestPayload: Decodable {
    let number: Int?
    let title: String?
    let url: String?
    let state: String?
    let isDraft: Bool?
    let mergeable: String?
    let mergeStateStatus: String?
    let reviewDecision: String?
    let headRefName: String?
    let statusCheckRollup: [CheckPayload]?
}

private struct CheckPayload: Decodable {
    let typeName: String?
    let name: String?
    let status: String?
    let conclusion: String?
    let detailsURL: String?
    let startedAt: String?
    let completedAt: String?
    let workflowName: String?
    let context: String?
    let state: String?
    let targetURL: String?
    let isRequired: Bool?
    let required: Bool?

    enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case name, status, conclusion, startedAt, completedAt, workflowName, context, state
        case detailsURL = "detailsUrl"
        case targetURL = "targetUrl"
        case isRequired, required
    }
}

private struct PullRequestSnapshot: Sendable {
    let pullRequest: PullRequest
    let runs: [CheckRun]
}

private actor GitHubCache {
    struct Key: Hashable, Sendable {
        let worktree: String
        let branch: String
    }

    struct Entry: Sendable {
        let snapshot: PullRequestSnapshot?
        let storedAt: ContinuousClock.Instant
    }

    private var entries: [Key: Entry] = [:]

    func value(for key: Key, maxAge: Duration) -> PullRequestSnapshot?? {
        guard maxAge > .zero, let entry = entries[key] else { return nil }
        guard entry.storedAt.duration(to: .now) <= maxAge else {
            entries[key] = nil
            return nil
        }
        return .some(entry.snapshot)
    }

    func store(_ snapshot: PullRequestSnapshot?, for key: Key) {
        entries[key] = Entry(snapshot: snapshot, storedAt: .now)
    }
}

/// The gh boundary centralizes JSON normalization, timeouts, and short-lived polling state.
public enum GitHub {
    /// Merge methods mirror gh flags so callers cannot construct an unsupported strategy.
    public enum MergeMethod: String, Sendable, CaseIterable {
        case merge
        case squash
        case rebase
    }

    private static let cache = GitHubCache()
    private static let fields = [
        "number", "title", "url", "state", "isDraft", "mergeable",
        "mergeStateStatus", "reviewDecision", "headRefName", "statusCheckRollup",
    ].joined(separator: ",")

    public static func isAvailable() async -> Bool {
        guard Shell.which("gh") != nil else { return false }
        guard let result = try? await Shell.run(
            "gh", ["auth", "status"], timeout: .seconds(20)
        ) else { return false }
        return result.ok
    }

    public static func pullRequest(
        forBranch branch: String,
        worktree: String,
        maxAge: Duration = .zero
    ) async throws -> PullRequest? {
        try await snapshot(forBranch: branch, worktree: worktree, maxAge: maxAge)?.pullRequest
    }

    public static func checks(
        forBranch branch: String,
        worktree: String,
        maxAge: Duration = .zero
    ) async throws -> [CheckRun] {
        try await snapshot(forBranch: branch, worktree: worktree, maxAge: maxAge)?.runs ?? []
    }

    /// This seam makes gh version differences testable without a repository or network access.
    public static func decodePullRequest(from data: Data) throws -> PullRequest {
        try decodeSnapshot(from: data).pullRequest
    }

    /// This seam applies the same requiredness policy to live output and deterministic tests.
    public static func rollup(_ runs: [CheckRun]) -> (PullRequest.Checks, String) {
        guard !runs.isEmpty else { return (.none, "No checks") }

        let failed = runs.filter(\.isFailure)
        let requiredFailures = failed.filter(\.isRequired)
        let optionalFailures = failed.filter { !$0.isRequired }
        let pending = runs.filter(\.isPending)

        if !requiredFailures.isEmpty {
            return (.failing, countSummary(requiredFailures.count, singular: "required check failed"))
        }
        if !pending.isEmpty {
            return (.pending, countSummary(pending.count, singular: "check pending"))
        }
        if !optionalFailures.isEmpty {
            return (.passing, countSummary(optionalFailures.count, singular: "optional check failed"))
        }
        return (.passing, countSummary(runs.count, singular: "check passed"))
    }

    public static func createPullRequest(
        worktree: String,
        base: String,
        title: String,
        body: String,
        draft: Bool
    ) async throws -> PullRequest {
        guard Git.isValidBranchName(base) else {
            throw GitHubError("refusing to open a pull request against '\(base)': not a valid branch name")
        }
        // Title and body only ever travel as the value of a flag, so no content of theirs can be
        // read as one.
        var arguments = ["pr", "create", "--base", base, "--title", title, "--body", body]
        if draft { arguments.append("--draft") }
        try await checkGH(arguments, worktree: worktree)

        let result = try await checkGH(
            ["pr", "view", "--json", fields], worktree: worktree
        )
        return try decodePullRequest(from: Data(result.stdout.utf8))
    }

    /// Merges the pull request, and then tidies up the remote branch if asked to.
    ///
    /// `--delete-branch` is deliberately never passed, and this is the one thing about merging
    /// from Bloom that has to be understood. That flag does two unrelated jobs: it deletes the
    /// branch on GitHub, which is a network call, and it then tidies up locally by checking out
    /// the base branch and deleting the merged branch. The local half runs `git` in the current
    /// directory, and Bloom's current directory is always a worktree. Git refuses to check out a
    /// branch that another checkout already holds, so from a worktree whose base is checked out in
    /// the main copy, which is every worktree this app makes, the local half fails with
    ///
    ///     failed to run git: fatal: 'main' is already used by worktree at '/path/to/repo'
    ///
    /// after the pull request has already merged. gh exits non-zero, and a caller that only looks
    /// at the exit status reports a merge that worked as a failure.
    ///
    /// So the merge is asked for on its own, and the remote branch is deleted afterwards with an
    /// explicit push, which touches no checkout at all. The local branch is left alone: the
    /// worktree is still standing on it, and archiving the workspace is what removes it, under
    /// the repository's own `delete_branch_on_archive` setting.
    @discardableResult
    public static func merge(
        number: Int,
        branch: String,
        worktree: String,
        method: MergeMethod,
        deleteRemoteBranch: Bool
    ) async throws -> MergeOutcome {
        let arguments = ["pr", "merge", String(number), "--\(method.rawValue)"]
        let result = try await Shell.run("gh", arguments, cwd: worktree, timeout: .seconds(20))

        guard result.ok else {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            // gh merges first and tidies up second, so a failure whose message is about the local
            // repository is a failure that happened after the pull request had already merged.
            // Reporting that as "could not merge" is a lie the user can check on GitHub.
            guard mergeFailedAfterMerging(stderr: stderr) else {
                throw shellError(arguments: arguments, result: result)
            }
            return MergeOutcome(leftover: .localTidyUp)
        }

        guard deleteRemoteBranch, !branch.isEmpty else { return MergeOutcome() }

        do {
            // Qualified, because the parameter of the same name shadows it here.
            try await Self.deleteRemoteBranch(branch, worktree: worktree)
            return MergeOutcome()
        } catch {
            return MergeOutcome(leftover: .remoteBranch(branch))
        }
    }

    /// Deletes `branch` on origin and nothing else. No checkout is touched, which is what makes
    /// this safe to run from a worktree.
    ///
    /// The branch travels as a fully qualified ref after `--`, for the reason spelled out on
    /// `push`: a branch named like a flag would otherwise rewrite the command.
    public static func deleteRemoteBranch(_ branch: String, worktree: String) async throws {
        guard Git.isValidBranchName(branch) else {
            throw GitHubError("refusing to delete '\(branch)' on origin: not a valid branch name")
        }

        let arguments = ["push", "--delete", "--", "origin", "refs/heads/\(branch)"]
        let result = try await Shell.run("git", arguments, cwd: worktree, timeout: .seconds(20))
        guard !result.ok else { return }

        // A repository set to delete head branches on merge has already removed it by the time we
        // ask, so the branch being gone is the outcome we wanted rather than a failure.
        guard !indicatesRemoteBranchGone(stderr: result.stderr + result.stdout) else { return }

        throw ShellError(
            command: "git " + arguments.joined(separator: " "),
            status: result.status,
            stderr: result.stderr.isEmpty ? result.stdout : result.stderr
        )
    }

    /// git has no exit code for "there was nothing to delete".
    public static func indicatesRemoteBranchGone(stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("remote ref does not exist")
    }

    /// git refuses to check out a branch that another worktree already holds.
    ///
    /// Load bearing for this whole app: every workspace is a worktree of a repository whose base
    /// branch is checked out in the main copy, so nothing Bloom runs may ever try to check out
    /// that base branch.
    public static func indicatesBranchCheckedOutElsewhere(stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("is already used by worktree")
            || stderr.localizedCaseInsensitiveContains("is already checked out at")
    }

    /// Whether a failed `gh pr merge` failed after the pull request had already merged.
    ///
    /// gh prefixes anything it could not do with git with `failed to run git`, and everything it
    /// does with git during a merge happens after the network call.
    public static func mergeFailedAfterMerging(stderr: String) -> Bool {
        indicatesBranchCheckedOutElsewhere(stderr: stderr)
            || stderr.localizedCaseInsensitiveContains("failed to run git")
    }

    /// Pushes the current HEAD to `branch` on origin.
    ///
    /// The branch never travels as a bare argument. Git will happily create a branch called
    /// `--mirror`, and `git push origin --mirror` is not a push: it makes the remote match the
    /// local repository exactly, deleting every remote branch and tag that is not here. Sending
    /// an explicit `HEAD:refs/heads/<branch>` refspec after `--` means the name can only ever be
    /// read as a ref, and the name is validated before we get that far.
    public static func push(worktree: String, branch: String, setUpstream: Bool) async throws {
        guard Git.isValidBranchName(branch) else {
            throw GitHubError("refusing to push to '\(branch)': not a valid branch name")
        }

        var arguments = ["push"]
        if setUpstream { arguments.append("--set-upstream") }
        arguments += ["--", "origin", "HEAD:refs/heads/\(branch)"]

        let result = try await Shell.run("git", arguments, cwd: worktree, timeout: .seconds(20))
        guard result.ok else {
            throw ShellError(
                command: "git " + arguments.joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    public static func hasRemoteBranch(_ branch: String, worktree: String) async -> Bool {
        guard Git.isValidBranchName(branch) else { return false }
        guard let result = try? await Shell.run(
            "git", ["ls-remote", "--exit-code", "--heads", "--", "origin", "refs/heads/\(branch)"],
            cwd: worktree,
            timeout: .seconds(20)
        ) else { return false }
        return result.ok
    }

    /// gh has no structured error code for a branch without a pull request.
    public static func indicatesNoPullRequest(stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("no pull requests found")
    }

    private static func snapshot(
        forBranch branch: String,
        worktree: String,
        maxAge: Duration
    ) async throws -> PullRequestSnapshot? {
        // gh reads its positional argument with the same parser it uses for flags, so a branch
        // called `--json` would rewrite the command.
        guard Git.isValidBranchName(branch) else {
            throw GitHubError("refusing to look up '\(branch)': not a valid branch name")
        }

        let key = GitHubCache.Key(worktree: worktree, branch: branch)
        if let cached = await cache.value(for: key, maxAge: maxAge) { return cached }

        let result = try await Shell.run(
            "gh", ["pr", "view", branch, "--json", fields],
            cwd: worktree,
            timeout: .seconds(20)
        )
        guard result.ok else {
            if indicatesNoPullRequest(stderr: result.stderr) {
                await cache.store(nil, for: key)
                return nil
            }
            throw shellError(arguments: ["pr", "view", branch, "--json", fields], result: result)
        }

        let snapshot = try decodeSnapshot(from: Data(result.stdout.utf8))
        await cache.store(snapshot, for: key)
        return snapshot
    }

    private static func decodeSnapshot(from data: Data) throws -> PullRequestSnapshot {
        let payload: PullRequestPayload
        do {
            payload = try JSONDecoder().decode(PullRequestPayload.self, from: data)
        } catch {
            let raw = String(decoding: data.suffix(1_024), as: UTF8.self)
            throw GitHubError("Could not decode gh JSON: \(error). Raw JSON tail: \(raw)")
        }

        let runs = (payload.statusCheckRollup ?? []).map(normalize)
        let (checks, summary) = rollup(runs)
        return PullRequestSnapshot(
            pullRequest: PullRequest(
                number: payload.number ?? 0,
                title: payload.title ?? "",
                url: payload.url ?? "",
                state: payload.state ?? "UNKNOWN",
                isDraft: payload.isDraft ?? false,
                mergeable: payload.mergeable ?? payload.mergeStateStatus,
                checks: checks,
                checksSummary: summary,
                reviewDecision: payload.reviewDecision,
                branch: payload.headRefName ?? ""
            ),
            runs: runs
        )
    }

    private static func normalize(_ payload: CheckPayload) -> CheckRun {
        if payload.typeName == "StatusContext" {
            let state = payload.state ?? "PENDING"
            return CheckRun(
                name: payload.context ?? "Status",
                status: state == "PENDING" || state == "EXPECTED" ? "PENDING" : "COMPLETED",
                conclusion: state,
                detailsURL: payload.targetURL,
                isRequired: payload.isRequired ?? payload.required
            )
        }

        return CheckRun(
            name: payload.name ?? payload.context ?? "Check",
            status: payload.status ?? "PENDING",
            conclusion: payload.conclusion,
            detailsURL: payload.detailsURL ?? payload.targetURL,
            startedAt: parseDate(payload.startedAt),
            completedAt: parseDate(payload.completedAt),
            workflowName: payload.workflowName,
            isRequired: payload.isRequired ?? payload.required
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(value))
    }

    private static func countSummary(_ count: Int, singular: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(singular.replacingOccurrences(of: "check ", with: "checks "))"
    }

    @discardableResult
    private static func checkGH(_ arguments: [String], worktree: String) async throws -> ShellResult {
        let result = try await Shell.run(
            "gh", arguments, cwd: worktree, timeout: .seconds(20)
        )
        guard result.ok else { throw shellError(arguments: arguments, result: result) }
        return result
    }

    private static func shellError(arguments: [String], result: ShellResult) -> ShellError {
        ShellError(
            command: "gh " + arguments.joined(separator: " "),
            status: result.status,
            stderr: result.stderr.isEmpty ? result.stdout : result.stderr
        )
    }
}

private extension CheckRun {
    var isPending: Bool {
        let normalizedStatus = status.uppercased()
        return normalizedStatus != "COMPLETED" && normalizedStatus != "SUCCESS" && normalizedStatus != "FAILURE" && normalizedStatus != "ERROR"
    }

    var isFailure: Bool {
        guard let conclusion else { return false }
        return [
            "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED",
            "STARTUP_FAILURE", "STALE",
        ].contains(conclusion.uppercased())
    }
}
