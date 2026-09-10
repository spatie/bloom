import Foundation

/// A pull request as the create window needs to talk about one: enough to list it, enough to name
/// the workspace after it, and enough to know which branch it will land on.
///
/// Separate from `PullRequest` on purpose. That type describes the pull request belonging to a
/// workspace that already exists, and every field on it is about status: mergeability, the review
/// decision, the check rollup. This one is about a pull request nothing has been checked out for
/// yet, so it carries the two things that type has no reason to know, the base ref and whether the
/// head lives in a fork, and none of the polling state.
public struct PullRequestListing: Sendable, Hashable, Identifiable, Codable {
    public let number: Int
    public let title: String
    public let author: String
    public let headRefName: String
    public let baseRefName: String
    public let isDraft: Bool
    /// `OPEN`, `CLOSED` or `MERGED`, as gh spells it.
    public let state: String
    /// Whether the head branch lives in a fork rather than in this repository.
    public let isCrossRepository: Bool
    /// The login owning the head repository, which is the fork's owner when there is one.
    public let headRepositoryOwner: String?

    public var id: Int { number }

    public var isOpen: Bool { state.uppercased() == "OPEN" }

    /// The branch this pull request lands on, named the way the picker should draw it.
    ///
    /// A fork's head is qualified with its owner, which is git's own convention for the ref and is
    /// not decoration: `heads(of:)` deliberately leaves a cross repository head out of the branches
    /// it hides, because a local branch of the same name is somebody else's unrelated work wearing
    /// the same word. Drawing both as a bare `patch-1` would put that collision on screen.
    ///
    /// Empty when an older gh did not answer `headRefName`, which is why every caller has to have
    /// something to fall back on rather than drawing a blank row.
    public var qualifiedHead: String {
        guard !headRefName.isEmpty else { return "" }
        guard isCrossRepository, let owner = headRepositoryOwner, !owner.isEmpty else {
            return headRefName
        }
        return "\(owner):\(headRefName)"
    }

    public init(
        number: Int,
        title: String,
        author: String = "",
        headRefName: String,
        baseRefName: String,
        isDraft: Bool = false,
        state: String = "OPEN",
        isCrossRepository: Bool = false,
        headRepositoryOwner: String? = nil
    ) {
        self.number = number
        self.title = title
        self.author = author
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.isDraft = isDraft
        self.state = state
        self.isCrossRepository = isCrossRepository
        self.headRepositoryOwner = headRepositoryOwner
    }
}

/// A branch that already exists somewhere, offered by the picker beside the pull requests.
public struct ExistingBranch: Sendable, Hashable, Identifiable, Codable {
    public let name: String
    /// Whether there is a local `refs/heads` copy. False means the branch is only on the remote,
    /// which needs a tracking branch made for it rather than a plain checkout.
    public let isLocal: Bool
    /// What is already sitting on this branch, or nil when it is free.
    ///
    /// Carried on the branch rather than worked out by the picker, because the picker used to be
    /// handed a list these branches had been taken out of: git refuses one branch in two
    /// worktrees, so an in-use branch was dropped, and the answer to "where is the branch I was
    /// working on yesterday" was silence. It is listed and marked instead, and selecting it goes
    /// to the workspace that has it. See `WorkspaceCheckoutPlan.workspaceHolding`, which is what
    /// turns a workspace holder back into the row to select.
    ///
    /// A `BranchHolder` rather than a workspace name, because Bloom's own workspaces are not the
    /// only thing that holds a branch on this Mac and the day it was a name was the day a
    /// Conductor worktree read as a free row. See `BranchHolder`.
    public let inUseBy: BranchHolder?

    public var id: String { name }

    public init(name: String, isLocal: Bool, inUseBy: BranchHolder? = nil) {
        self.name = name
        self.isLocal = isLocal
        self.inUseBy = inUseBy
    }
}

/// What a workspace is opened on, when it is not opened on a new branch.
///
/// The whole point of the feature: Bloom could only ever cut a branch, so it was where work is
/// delegated and never where work is reviewed. A checkout is the other direction, and the two
/// cases below are the same shape of thing, an existing head somebody else wrote, which is why
/// they travel as one value through `WorkspaceStartRequest`.
public enum WorkspaceCheckout: Sendable, Hashable, Codable {
    case pullRequest(PullRequestListing)
    case branch(ExistingBranch)
}
