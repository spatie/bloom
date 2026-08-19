import Foundation

/// Everything that decides whether Bloom may rename the branch it cut a few seconds ago.
///
/// A value, gathered once and then reasoned about, rather than a series of questions asked inside
/// the decision. That is deliberate: a rename is the only thing in this feature that can break
/// somebody's work, and the rule for when it is allowed has to be readable in one place and
/// testable without a repository.
public struct BranchRenameFacts: Sendable, Hashable {
    /// The branch the workspace row says it is on.
    public var recordedBranch: String
    /// The branch actually checked out in the worktree, or nil for a detached HEAD.
    public var checkedOutBranch: String?
    /// What the rename would produce.
    public var desiredBranch: String
    /// Commits on this branch that the base branch does not have.
    public var commitsAhead: Int
    /// A tracking branch is configured.
    public var hasUpstream: Bool
    /// A remote-tracking ref with this branch's name exists locally, which means it has been
    /// pushed at least once, whether or not an upstream was set.
    public var hasRemoteCounterpart: Bool
    /// Bloom or GitHub knows of a pull request for this branch.
    public var hasPullRequest: Bool
    /// A rebase, merge, cherry-pick or bisect is half finished in this worktree.
    public var hasOperationInProgress: Bool
    /// Every branch name already used in the repository.
    public var takenBranches: Set<String>

    public init(
        recordedBranch: String,
        checkedOutBranch: String?,
        desiredBranch: String,
        commitsAhead: Int = 0,
        hasUpstream: Bool = false,
        hasRemoteCounterpart: Bool = false,
        hasPullRequest: Bool = false,
        hasOperationInProgress: Bool = false,
        takenBranches: Set<String> = []
    ) {
        self.recordedBranch = recordedBranch
        self.checkedOutBranch = checkedOutBranch
        self.desiredBranch = desiredBranch
        self.commitsAhead = commitsAhead
        self.hasUpstream = hasUpstream
        self.hasRemoteCounterpart = hasRemoteCounterpart
        self.hasPullRequest = hasPullRequest
        self.hasOperationInProgress = hasOperationInProgress
        self.takenBranches = takenBranches
    }
}

/// Why a rename did not happen. Each case carries the sentence the user is shown, because a
/// refusal nobody can read is the same as a silent one.
public enum BranchRenameRefusal: Sendable, Hashable {
    /// Not a refusal so much as nothing to do: the branch is already what we wanted.
    case alreadyNamed
    /// The model gave nothing git would accept, or gave nothing at all.
    case noValidName
    case hasCommits(Int)
    case pushed
    case hasPullRequest
    case renamedByHand(String)
    case detachedHead
    case operationInProgress
    case nameTaken(String)
    /// Every check passed and `git branch -m` still refused. Rare, and carried verbatim rather
    /// than guessed at, because inventing a reason here would be worse than quoting git.
    case gitRefused(String)

    /// The half sentence that goes after "the branch is still `x`".
    ///
    /// Written to finish the sentence rather than to stand alone, so the notice reads as one
    /// thought: "Bloom named this workspace Dark mode toggle. The branch is still
    /// `add-a-toggle-to-settings`, because it already has 2 commits on it."
    public var reason: String {
        switch self {
        case .alreadyNamed:
            "it already has the name Bloom would have given it"
        case .noValidName:
            "the model did not come back with a branch name git would accept"
        case .hasCommits(let count):
            "it already has \(count) commit\(count == 1 ? "" : "s") on it"
        case .pushed:
            "it has already been pushed, and renaming it here would leave the pushed one behind"
        case .hasPullRequest:
            "it has a pull request open against it"
        case .renamedByHand(let branch):
            "you are on \(branch) now, which is not the branch Bloom created"
        case .detachedHead:
            "this worktree is not on a branch at all"
        case .operationInProgress:
            "a rebase or merge is half finished in this worktree"
        case .nameTaken(let branch):
            "\(branch) is already taken by another branch"
        case .gitRefused(let message):
            "git refused to rename it: \(message)"
        }
    }

    /// Whether this refusal is worth telling the user about.
    ///
    /// Two of them are not. `alreadyNamed` means nothing changed and nothing needed to;
    /// `noValidName` means the branch is the mechanical one it always was, which is exactly what
    /// the user would have had with this feature turned off. The rest are all cases where the
    /// workspace's name moved and its branch did not, which is the one thing that must never
    /// happen quietly.
    public var isWorthReporting: Bool {
        switch self {
        case .alreadyNamed, .noValidName: false
        default: true
        }
    }
}

public enum BranchRenameDecision: Sendable, Hashable {
    case rename(to: String)
    case refuse(BranchRenameRefusal)

    public var refusal: BranchRenameRefusal? {
        if case .refuse(let refusal) = self { return refusal }
        return nil
    }
}

public enum BranchRenameGate {
    /// Whether the branch may be renamed, and to what.
    ///
    /// A branch may only be renamed while nothing depends on its old name. By the time a model
    /// answers, the worktree exists, the setup script may have run and the agent may already be
    /// working, so every one of these is a thing that can genuinely have happened in the five
    /// seconds since the branch was cut.
    ///
    /// The order is chosen so the reported reason is the most specific true one. Someone who has
    /// pushed a branch with a pull request open is told about the pull request, because that is
    /// the fact they would act on.
    public static func decide(_ facts: BranchRenameFacts) -> BranchRenameDecision {
        let desired = facts.desiredBranch.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !desired.isEmpty, Git.isValidBranchName(desired) else {
            return .refuse(.noValidName)
        }
        guard desired != facts.recordedBranch else {
            return .refuse(.alreadyNamed)
        }

        // The user's own hands come first. Anything they did to this branch outranks anything a
        // model suggested, and it is also the loudest signal that they are already using the name.
        guard let checkedOut = facts.checkedOutBranch else {
            return .refuse(.detachedHead)
        }
        guard checkedOut == facts.recordedBranch else {
            return .refuse(.renamedByHand(checkedOut))
        }

        // Then everything outside this machine, because those are the ones a local rename cannot
        // put right afterwards.
        if facts.hasPullRequest { return .refuse(.hasPullRequest) }
        if facts.hasUpstream || facts.hasRemoteCounterpart { return .refuse(.pushed) }

        // Then the work in this repository.
        if facts.hasOperationInProgress { return .refuse(.operationInProgress) }
        if facts.commitsAhead > 0 { return .refuse(.hasCommits(facts.commitsAhead)) }

        // Last, the name itself. Not made unique with a `-2` suffix on purpose: a suffix would
        // mean the sidebar says one thing and the branch says something a digit different, and
        // the branch it already has is a perfectly good one.
        if facts.takenBranches.contains(desired) {
            return .refuse(.nameTaken(desired))
        }

        return .rename(to: desired)
    }
}
