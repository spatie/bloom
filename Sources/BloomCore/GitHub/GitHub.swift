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

/// Whether the GitHub CLI can be used, and if not, why not.
///
/// Two failures rather than one, because they are different problems: `gh` missing is fixed by
/// installing it, `gh` signed out is fixed by signing in, and a sentence that covers both says
/// nothing useful about either.
public enum GitHubAccess: Sendable, Equatable {
    case ready
    case notInstalled
    case signedOut
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
    /// When the pull request stopped being open. GitHub sets it for merged as well as closed, and
    /// leaves it null while the pull request is open, so one field answers both.
    let closedAt: String?
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
        // Read for one reason: telling a pull request that ended before this workspace was
        // started apart from this workspace's own. See `PullRequestOwnership`.
        "closedAt",
    ].joined(separator: ",")

    public static func isAvailable() async -> Bool {
        await access() == .ready
    }

    /// Why gh cannot be used, when it cannot.
    ///
    /// The two failures are different problems with different fixes, and collapsing them into one
    /// "unavailable" means the app cannot write the right sentence: a machine with no `gh` needs
    /// to install it, and a login button there could only fail.
    ///
    /// Nothing about the answer is kept but the case. `gh auth status` prints the account, the
    /// host and the token's scopes, and with `--show-token`, which is never passed, the token
    /// itself. None of that output is stored, logged or shown anywhere.
    public static func access() async -> GitHubAccess {
        guard Shell.which("gh") != nil else { return .notInstalled }
        guard let result = try? await Shell.run(
            "gh", ["auth", "status"], timeout: .seconds(20)
        ) else {
            // Installed, but the probe itself did not finish. Signing in is the fix that fixes
            // this too, and it is the only one there is a button for.
            return .signedOut
        }
        return result.ok ? .ready : .signedOut
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

    /// The same seam for the runs themselves, which the pull request rolls up and therefore hides.
    public static func decodeChecks(from data: Data) throws -> [CheckRun] {
        try decodeSnapshot(from: data).runs
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

    /// The log of a failed check run, as gh prints it.
    ///
    /// `--log-failed` rather than `--log`, because a workflow that ran twelve steps and failed on
    /// one prints eleven steps of noise before the thing the user clicked on. It is asked for the
    /// job wherever the check gave us one, so a matrix of eight jobs does not hand over the seven
    /// that passed.
    ///
    /// Two attempts, not one. `--log-failed` prints nothing at all when GitHub considers the job
    /// to have failed without any step failing, which is what a cancellation, a timeout and a
    /// runner that died all look like, and an empty log is the case this feature exists to avoid.
    /// So an empty answer falls back to the whole log, which is long but is at least the log.
    ///
    /// A generous timeout, because this is one archive download rather than a metadata call, and
    /// because it is only ever run when somebody pressed a button and is waiting for it.
    public static func checkRunLog(
        _ target: CheckFailureHandoff.LogTarget,
        worktree: String,
        timeout: Duration = .seconds(90)
    ) async throws -> String {
        var selector = [target.runID]
        if let jobID = target.jobID { selector = ["--job", jobID] }

        let failed = try await Shell.run(
            "gh", ["run", "view"] + selector + ["--log-failed"], cwd: worktree, timeout: timeout
        )
        let trimmed = failed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if failed.ok, !trimmed.isEmpty { return failed.stdout }

        let whole = try await Shell.run(
            "gh", ["run", "view"] + selector + ["--log"], cwd: worktree, timeout: timeout
        )
        guard whole.ok, !whole.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // The first call's message where there is one: `--log-failed` is what was asked for
            // and its complaint is the one that describes the request.
            let reason = [failed.stderr, whole.stderr]
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            throw GitHubError(reason.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? "gh returned no log for this check run")
        }
        return whole.stdout
    }

    // Merging is not here, and its absence is the point.
    //
    // `gh pr merge` used to run from this file, followed by an explicit
    // `git push --delete -- origin refs/heads/<branch>`, because `--delete-branch` makes gh check
    // out the base branch and a worktree cannot check out the branch the main copy is standing on.
    // Both commands now live in `MergeInstructions`, a file in the repository that the workspace's
    // agent is asked to follow, and everything that was known about them here is written down
    // there in the words the agent reads. There is one way to merge a pull request in this app and
    // it goes through the transcript.

    /// Pushes the current HEAD to `branch` on origin.
    ///
    /// The branch never travels as a bare argument. Git will happily create a branch called
    /// `--mirror`, and `git push origin --mirror` is not a push: it makes the remote match the
    /// local repository exactly, deleting every remote branch and tag that is not here. Sending
    /// an explicit `HEAD:refs/heads/<branch>` refspec after `--` means the name can only ever be
    /// read as a ref, and the name is validated before we get that far.
    ///
    /// - Parameter timeout: raised by the caller that pushes a whole project for the first time.
    ///   Twenty seconds is plenty for a branch that is a few commits ahead of a remote that
    ///   already has the history, and nowhere near enough for the first upload of a repository.
    public static func push(
        worktree: String,
        branch: String,
        setUpstream: Bool,
        timeout: Duration = .seconds(20)
    ) async throws {
        guard Git.isValidBranchName(branch) else {
            throw GitHubError("refusing to push to '\(branch)': not a valid branch name")
        }

        var arguments = ["push"]
        if setUpstream { arguments.append("--set-upstream") }
        arguments += ["--", "origin", "HEAD:refs/heads/\(branch)"]

        let result = try await Shell.run("git", arguments, cwd: worktree, timeout: timeout)
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
                if let fallback = try await snapshotOfCheckedOutBranch(branch, worktree: worktree) {
                    await cache.store(fallback, for: key)
                    return fallback
                }
                await cache.store(nil, for: key)
                return nil
            }
            throw shellError(arguments: ["pr", "view", branch, "--json", fields], result: result)
        }

        let snapshot = try decodeSnapshot(from: Data(result.stdout.utf8))
        await cache.store(snapshot, for: key)
        return snapshot
    }

    /// The pull request of the branch this worktree is actually on, asked without naming it.
    ///
    /// Named, a branch is looked up as `<this repository's owner>:<branch>`, and a pull request
    /// from a fork has its head in the contributor's repository, so the named lookup answers "no
    /// pull requests found" for a branch that plainly has one. Unnamed, gh resolves the pull
    /// request from the checked out branch's own config, which `gh pr checkout` writes as
    /// `refs/pull/N/head`, and finds it. That is the only route that works for a fork, and Bloom
    /// now opens workspaces on other people's pull requests, so it is no longer an exotic case:
    /// without this the review workspace showed "no pull request yet" beside its own review.
    ///
    /// The answer is only accepted when it is about the branch that was asked about. A worktree
    /// somebody has switched to another branch would otherwise report that branch's pull request
    /// under this one's name.
    private static func snapshotOfCheckedOutBranch(
        _ branch: String, worktree: String
    ) async throws -> PullRequestSnapshot? {
        guard let result = try? await Shell.run(
            "gh", ["pr", "view", "--json", fields], cwd: worktree, timeout: .seconds(20)
        ), result.ok else { return nil }

        let snapshot = try decodeSnapshot(from: Data(result.stdout.utf8))
        guard snapshot.pullRequest.branch == branch else { return nil }
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
                branch: payload.headRefName ?? "",
                closedAt: parseDate(payload.closedAt)
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

    /// Every timestamp gh prints, read in one place.
    ///
    /// There were two of these twenty five lines apart, over the same JSON from the same command,
    /// and they disagreed about the case below: `closedAt` went through the copy with no zero time
    /// guard, so a pull request Go had never closed came back closed in the year one rather than
    /// not closed at all. The copy that knew about it was the one used for check runs.
    private static func parseDate(_ value: String?) -> Date? {
        // gh marshals a Go `time.Time` that was never set as year one rather than omitting it, so
        // a check that has not started carries a real, parseable, meaningless date at both ends of
        // its clock. Taken at face value a queued run measured zero seconds and the list reported
        // "0s" beside a job nothing had begun.
        guard let value, !value.isEmpty, !value.hasPrefix("0001-01-01") else { return nil }
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

// MARK: - Creating a repository

/// Who a new repository could belong to.
public struct GitHubOwner: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case user
        case organization
    }

    public let login: String
    public let kind: Kind

    public var id: String { login }

    public init(login: String, kind: Kind) {
        self.login = login
        self.kind = kind
    }
}

private struct LoginPayload: Decodable {
    let login: String
}

public extension GitHub {
    /// The accounts this token may create a repository under: the signed in user first, then every
    /// organisation they belong to.
    ///
    /// Membership is not the same as permission. An organisation can forbid members from creating
    /// repositories, and there is no cheap way to ask which ones do, so the list is what the user
    /// belongs to and a refusal comes back from the create step with GitHub's own wording. Being
    /// told "you are not allowed to create repositories in this org" is a better outcome than
    /// hiding the org and leaving the user wondering where it went.
    static func owners() async throws -> [GitHubOwner] {
        let me = try await api(["user"], timeout: .seconds(20))
        let user = try JSONDecoder().decode(LoginPayload.self, from: Data(me.utf8))

        var owners = [GitHubOwner(login: user.login, kind: .user)]
        // Organisations are a nicety. A token without `read:org` returns nothing useful here, and
        // that must not stop somebody creating a repository under their own account.
        if let orgs = try? await api(["user/orgs", "--paginate"], timeout: .seconds(20)),
           let decoded = try? JSONDecoder().decode([LoginPayload].self, from: Data(orgs.utf8)) {
            owners += decoded.map { GitHubOwner(login: $0.login, kind: .organization) }
        }
        return owners
    }

    /// Whether `owner/name` already exists.
    ///
    /// Three answers, not two. A check that could not reach GitHub returns `unknown` carrying the
    /// reason, because reporting a name as free on the strength of a failed request is how a user
    /// ends up pressing a button that fails after their folder has already been committed.
    ///
    /// One blind spot worth naming: a repository that exists but this token cannot see answers 404
    /// like one that does not exist. That reads as available here and is refused by GitHub at
    /// creation time, with GitHub's own sentence.
    static func repositoryAvailability(owner: String, name: String) async -> NameAvailability {
        guard GitHubRepositoryName.isValid(name), isPlausibleLogin(owner) else {
            return .unknown("Bloom did not check that name.")
        }
        guard let result = try? await Shell.run(
            "gh", ["api", "--silent", "repos/\(owner)/\(name)"], timeout: .seconds(15)
        ) else {
            return .unknown("Bloom could not reach GitHub to check that name.")
        }
        if result.ok { return .taken }

        let output = result.stderr + result.stdout
        if output.contains("HTTP 404") || output.localizedCaseInsensitiveContains("not found") {
            return .available
        }
        return .unknown("Bloom could not check that name with GitHub.")
    }

    /// Creates an empty repository and returns the URL to add as `origin`.
    ///
    /// Nothing is pushed here. `gh repo create --source --push` would do the whole thing in one
    /// call, and it is deliberately not used: the create and the push fail for different reasons
    /// and leave the folder in different states, and a single exit code cannot tell the user which
    /// of the two happened.
    ///
    /// `isPrivate` has no default. Publishing somebody's folder is not a thing to get by omission.
    static func createRepository(
        owner: String, name: String, isPrivate: Bool
    ) async throws -> String {
        if let problem = GitHubRepositoryName.problem(with: name) {
            throw GitHubError(problem.sentence)
        }
        guard isPlausibleLogin(owner) else {
            throw GitHubError("'\(owner)' is not a GitHub account name.")
        }

        let arguments = [
            "repo", "create", "\(owner)/\(name)", isPrivate ? "--private" : "--public",
        ]
        let result = try await Shell.run("gh", arguments, timeout: .seconds(60))
        guard result.ok else {
            throw ShellError(
                command: "gh " + arguments.joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return await remoteURL(owner: owner, name: name)
    }

    /// The address to give `origin`, in whichever protocol the user has told gh they prefer.
    /// Somebody who clones over SSH everywhere should not get one HTTPS remote from Bloom.
    static func remoteURL(owner: String, name: String) async -> String {
        let configured = try? await Shell.run(
            "gh", ["config", "get", "git_protocol"], timeout: .seconds(10)
        )
        let usesSSH = (configured?.ok ?? false) && configured?.trimmed == "ssh"
        return usesSSH
            ? "git@github.com:\(owner)/\(name).git"
            : "https://github.com/\(owner)/\(name).git"
    }

    /// The page to open once a repository exists.
    static func repositoryPage(owner: String, name: String) -> String {
        "https://github.com/\(owner)/\(name)"
    }

    /// GitHub logins are alphanumerics and single hyphens. Checked because the login reaches gh as
    /// part of a path and as part of a URL.
    static func isPlausibleLogin(_ login: String) -> Bool {
        guard !login.isEmpty, login.count <= 39, !login.hasPrefix("-"), !login.hasSuffix("-") else {
            return false
        }
        return login.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func api(_ path: [String], timeout: Duration) async throws -> String {
        let arguments = ["api"] + path
        let result = try await Shell.run("gh", arguments, timeout: timeout)
        guard result.ok else {
            throw ShellError(
                command: "gh " + arguments.joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result.stdout
    }
}
