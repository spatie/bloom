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

private struct RepositoryPayload: Decodable {
    let nameWithOwner: String?
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
        "mergeStateStatus", "reviewDecision", "statusCheckRollup",
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
        var arguments = ["pr", "create", "--base", base, "--title", title, "--body", body]
        if draft { arguments.append("--draft") }
        try await checkGH(arguments, worktree: worktree)

        let result = try await checkGH(
            ["pr", "view", "--json", fields], worktree: worktree
        )
        return try decodePullRequest(from: Data(result.stdout.utf8))
    }

    public static func merge(
        number: Int,
        worktree: String,
        method: MergeMethod,
        deleteBranch: Bool
    ) async throws {
        var arguments = ["pr", "merge", String(number), "--\(method.rawValue)"]
        if deleteBranch { arguments.append("--delete-branch") }
        try await checkGH(arguments, worktree: worktree)
    }

    public static func push(worktree: String, branch: String, setUpstream: Bool) async throws {
        var arguments = ["push"]
        if setUpstream { arguments += ["--set-upstream", "origin"] }
        arguments.append(branch)
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
        guard let result = try? await Shell.run(
            "git", ["ls-remote", "--exit-code", "--heads", "origin", "refs/heads/\(branch)"],
            cwd: worktree,
            timeout: .seconds(20)
        ) else { return false }
        return result.ok
    }

    public static func repositoryNameWithOwner(worktree: String) async -> String? {
        guard let result = try? await Shell.run(
            "gh", ["repo", "view", "--json", "nameWithOwner"],
            cwd: worktree,
            timeout: .seconds(20)
        ), result.ok else { return nil }

        return try? JSONDecoder().decode(
            RepositoryPayload.self, from: Data(result.stdout.utf8)
        ).nameWithOwner
    }

    public static func openInBrowser(_ url: String) async {
        _ = try? await Shell.run("/usr/bin/open", [url], timeout: .seconds(20))
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
                reviewDecision: payload.reviewDecision
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
