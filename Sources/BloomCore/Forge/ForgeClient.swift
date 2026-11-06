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
