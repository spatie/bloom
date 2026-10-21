import Foundation

/// What a direct merge checks on either forge before running the CLI: the request as shown, this
/// checkout at its head, and a fresh read that still says the same. GitHub's words stay as they were.
enum DirectMergeCheck {
    /// The confirmed head commit and base branch, once this checkout is known to be exactly that.
    static func confirmed(
        _ expected: PullRequest, base: String, worktree: String
    ) async throws -> (head: String, base: String) {
        let forge = expected.forge
        guard expected.number > 0, !expected.url.isEmpty,
              let head = expected.headRevision, isCommitID(head),
              let expectedBase = expected.baseBranch, !expectedBase.isEmpty else {
            throw GitHubError("Refresh the \(forge.request) before merging directly.")
        }
        if !expected.branch.isEmpty,
           try await Git.currentBranch(of: worktree) != expected.branch {
            throw GitHubError("This worktree is no longer on the \(forge.request)'s branch.")
        }

        let local = try await Git.localWork(worktree: worktree)
        guard !local.isAhead else {
            throw GitHubError("This worktree has changes or commits \(forge.name) has not got. Commit and push them, or choose the agent route after reviewing the warning.")
        }
        guard try await Git.headSHA(of: worktree) == head else {
            throw GitHubError("This checkout is not at the \(forge.request)'s head commit. Refresh or update it before merging directly.")
        }

        let context = try await Git.repositoryContext(in: worktree, baseBranch: base)
        guard expectedBase == context.baseBranch else {
            throw GitHubError("The \(forge.request) targets \(expectedBase), not \(context.baseBranch). Refresh it before merging.")
        }
        return (head, expectedBase)
    }

    /// A fresh read of the same request: unchanged since it was shown, and still mergeable.
    static func verify(_ current: PullRequest?, against expected: PullRequest, head: String, base: String) throws {
        let forge = expected.forge
        guard let current else {
            throw GitHubError("\(forge.name) no longer has \(forge.request) \(forge.reference(expected.number)).")
        }
        guard current.url == expected.url, current.branch == expected.branch,
              current.baseBranch == base, current.headRevision == head else {
            throw GitHubError("The \(forge.request) changed since it was shown. Refresh it before merging.")
        }
        guard current.isOpen, current.status.canMerge else {
            throw GitHubError(current.status.blockedReason ?? "This \(forge.request) can no longer be merged.")
        }
    }

    static func isCommitID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}
