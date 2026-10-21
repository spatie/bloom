import Foundation

/// The pull request operations more than one forge answers. Each requirement takes only what its
/// callers pass, so every default stays on `GitHub` rather than being restated here.
public protocol ForgeClient {
    static func access(in directory: String) async -> GitHubAccess
    static func readPullRequest(for workspace: Workspace, maxAge: Duration) async -> PullRequestRead
    static func pullRequest(for workspace: Workspace, maxAge: Duration) async throws -> PullRequest?
    static func pullRequest(forBranch branch: String, worktree: String) async throws -> PullRequest?
    static func checks(for workspace: Workspace) async throws -> [CheckRun]?
    static func markReadyForReview(_ pullRequest: PullRequest, worktree: String) async throws
    static func checkRunLog(_ target: CheckFailureHandoff.LogTarget, worktree: String) async throws -> String
    static func openPullRequests(repoPath: String) async throws -> [PullRequestListing]
    static func pullRequestSummary(number: Int, repoPath: String) async throws -> PullRequestListing
    static func repositorySlug(repoPath: String) async -> String?
    static func checkoutPullRequest(number: Int, into worktree: String, localBranch: String) async throws
    static func createPullRequestFromCommits(worktree: String, base: String, title: String) async throws -> PullRequest
    static func mergePullRequest(
        _ expected: PullRequest, into base: String, method: GitHub.MergeMethod,
        squashMessage: SquashCommitMessage?, worktree: String
    ) async throws -> DirectMergeOutcome
}

/// `GitHub` as a `ForgeClient`. It only forwards.
public enum GitHubForge: ForgeClient {
    /// gh signs in once for every repository, so the directory changes nothing here.
    public static func access(in directory: String) async -> GitHubAccess {
        await GitHub.access()
    }

    public static func readPullRequest(for workspace: Workspace, maxAge: Duration) async -> PullRequestRead {
        await GitHub.readPullRequest(for: workspace, maxAge: maxAge)
    }

    public static func pullRequest(for workspace: Workspace, maxAge: Duration) async throws -> PullRequest? {
        try await GitHub.pullRequest(for: workspace, maxAge: maxAge)
    }

    public static func pullRequest(forBranch branch: String, worktree: String) async throws -> PullRequest? {
        try await GitHub.pullRequest(forBranch: branch, worktree: worktree)
    }

    public static func checks(for workspace: Workspace) async throws -> [CheckRun]? {
        try await GitHub.checks(for: workspace)
    }

    public static func markReadyForReview(_ pullRequest: PullRequest, worktree: String) async throws {
        try await GitHub.markReadyForReview(pullRequest, worktree: worktree)
    }

    public static func checkRunLog(
        _ target: CheckFailureHandoff.LogTarget, worktree: String
    ) async throws -> String {
        // A GitLab job's page, on a repository GitHub reports for: not a run gh can find.
        guard target.project == nil else { throw GitHubError("This check's log is not on GitHub.") }
        return try await GitHub.checkRunLog(target, worktree: worktree)
    }

    public static func openPullRequests(repoPath: String) async throws -> [PullRequestListing] {
        try await GitHub.openPullRequests(repoPath: repoPath)
    }

    public static func pullRequestSummary(number: Int, repoPath: String) async throws -> PullRequestListing {
        try await GitHub.pullRequestSummary(number: number, repoPath: repoPath)
    }

    public static func repositorySlug(repoPath: String) async -> String? {
        await GitHub.repositorySlug(repoPath: repoPath)
    }

    public static func checkoutPullRequest(number: Int, into worktree: String, localBranch: String) async throws {
        try await GitHub.checkoutPullRequest(number: number, into: worktree, localBranch: localBranch)
    }

    public static func createPullRequestFromCommits(
        worktree: String, base: String, title: String
    ) async throws -> PullRequest {
        try await GitHub.createPullRequestFromCommits(worktree: worktree, base: base, title: title)
    }

    public static func mergePullRequest(
        _ expected: PullRequest, into base: String, method: GitHub.MergeMethod,
        squashMessage: SquashCommitMessage?, worktree: String
    ) async throws -> DirectMergeOutcome {
        try await GitHub.mergePullRequest(
            expected, into: base, method: method, squashMessage: squashMessage, worktree: worktree
        )
    }
}
