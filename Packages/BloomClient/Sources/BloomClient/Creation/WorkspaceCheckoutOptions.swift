import Foundation

/// What the create window can offer to open, as opposed to what it can cut a branch from.
///
/// Loaded separately from `WorkspaceStartContext` and after it, because listing pull requests is a
/// network call: the sheet has to be typeable the moment it opens, and a project whose GitHub is
/// slow or unreachable must delay the picker rather than the composer.
public struct WorkspaceCheckoutOptions: Sendable, Codable {
    public let pullRequests: [PullRequestListing]
    public let branches: [ExistingBranch]
    /// Why there are no pull requests, when gh is the reason. `ready` with an empty list means the
    /// repository genuinely has none open, which is a different sentence.
    public let access: GitHubAccess
    /// What went wrong talking to GitHub, when something did. Shown rather than swallowed: a
    /// picker that silently lists nothing is indistinguishable from a repository at peace.
    public let failure: String?
    /// Every branch of this repository that is already checked out somewhere, and by what.
    ///
    /// Carried whole as well as folded into `branches`, because a pull request row needs the same
    /// answer about its head and is not an `ExistingBranch`. That is the row #362 was: the branch
    /// half of the picker knew the branch was taken and the pull request half did not, so the one
    /// that reached `git worktree add` was the one that could not have worked.
    public let holders: [String: BranchHolder]

    public init(
        pullRequests: [PullRequestListing] = [],
        branches: [ExistingBranch] = [],
        access: GitHubAccess = .ready,
        failure: String? = nil,
        holders: [String: BranchHolder] = [:]
    ) {
        self.pullRequests = pullRequests
        self.branches = branches
        self.access = access
        self.failure = failure
        self.holders = holders
    }

}
