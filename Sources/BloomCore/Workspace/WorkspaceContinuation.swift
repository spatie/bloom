import Foundation

/// Everything that decides whether a workspace whose pull request has landed may carry on in
/// place, and on what branch.
///
/// A value gathered once and then reasoned about, the same shape as `BranchRenameFacts`, and for
/// the same reason: this is the other operation in the app that moves a worktree's HEAD, so the
/// rule for when it is allowed has to be readable in one place and testable without a repository.
///
/// Continuing is deliberately NOT a rename. `BranchRenameGate` decides whether the branch Bloom
/// cut a moment ago may be given a better name while nothing depends on the old one. Here
/// everything depends on the old one: it has commits, it was pushed, it had a pull request and
/// that pull request is merged. So the old branch is left exactly where it is and a new one is
/// cut beside it. Nothing is renamed, nothing is deleted, and the merged branch stays on this
/// machine until the workspace is archived like any other.
public struct ContinuationFacts: Sendable, Hashable {
    /// The branch the workspace row says it is on.
    public var recordedBranch: String
    /// The branch actually checked out in the worktree, or nil for a detached HEAD.
    public var checkedOutBranch: String?
    /// The branch the finished pull request targeted, and the one the new branch is cut from.
    public var baseBranch: String
    /// GitHub says the pull request for `recordedBranch` was merged. Only ever true when GitHub
    /// actually said so: this is the whole justification for moving off the branch, so it is
    /// never inferred from silence.
    public var isPullRequestMerged: Bool
    /// An agent is mid turn in this workspace right now.
    public var isAgentRunning: Bool
    /// A rebase, merge, cherry-pick, revert or bisect is half finished in this worktree.
    public var hasOperationInProgress: Bool
    /// Every branch name already used in the repository.
    public var takenBranches: Set<String>

    public init(
        recordedBranch: String,
        checkedOutBranch: String?,
        baseBranch: String,
        isPullRequestMerged: Bool = false,
        isAgentRunning: Bool = false,
        hasOperationInProgress: Bool = false,
        takenBranches: Set<String> = []
    ) {
        self.recordedBranch = recordedBranch
        self.checkedOutBranch = checkedOutBranch
        self.baseBranch = baseBranch
        self.isPullRequestMerged = isPullRequestMerged
        self.isAgentRunning = isAgentRunning
        self.hasOperationInProgress = hasOperationInProgress
        self.takenBranches = takenBranches
    }
}

/// Why a workspace was not continued. Each case carries the sentence the user is shown, because a
/// refusal nobody can read is the same as a silent one.
public enum ContinuationRefusal: Sendable, Hashable {
    case notMerged
    case agentRunning
    case detachedHead
    case switchedByHand(String)
    case operationInProgress
    case onBaseBranch(String)
    case noValidName

    /// A whole sentence, unlike `BranchRenameRefusal.reason`. That one finishes a sentence the
    /// notice already started; this one is the only thing the user is shown, because pressing
    /// Continue and having nothing happen needs its own explanation.
    public var sentence: String {
        switch self {
        case .notMerged:
            "Continue is for a workspace whose pull request has landed. This one has not."
        case .agentRunning:
            "An agent is working in this workspace. Continuing would move the branch under it. "
                + "Wait for the turn to finish, then press Continue again."
        case .detachedHead:
            "This worktree is not on a branch at all. Commits made on a detached HEAD are held by "
                + "nothing but this checkout, so Bloom will not move it."
        case .switchedByHand(let branch):
            "This worktree is on \(branch) now, which is not the branch the pull request was for. "
                + "Bloom only continues a workspace that is still where it left it."
        case .operationInProgress:
            "A rebase or merge is half finished in this worktree. Finish or abort it first."
        case .onBaseBranch(let branch):
            "This worktree is on \(branch), which is the branch everything is merged into. "
                + "There is nothing to continue from here."
        case .noValidName:
            "Bloom could not work out a branch name to continue on."
        }
    }
}

public enum ContinuationDecision: Sendable, Hashable {
    case cut(branch: String)
    case refuse(ContinuationRefusal)

    public var branch: String? {
        if case .cut(let branch) = self { return branch }
        return nil
    }

    public var refusal: ContinuationRefusal? {
        if case .refuse(let refusal) = self { return refusal }
        return nil
    }
}

public enum ContinuationGate {
    /// Whether this workspace may carry on in place, and on what branch.
    ///
    /// The order is chosen so the reported reason is the most specific true one, the same way
    /// `BranchRenameGate` orders its own. Someone whose agent is running while a rebase is half
    /// finished is told about the agent, because that is the one they can do something about
    /// right now.
    public static func decide(_ facts: ContinuationFacts) -> ContinuationDecision {
        // The merge is the entire justification. Without it the branch is still live work and
        // moving off it would leave the pull request pointing at a branch nobody is on.
        guard facts.isPullRequestMerged else { return .refuse(.notMerged) }

        // A running agent first. It is writing to this worktree right now, and `git checkout -b`
        // under a process that is halfway through editing a file is the one way this feature
        // could destroy something.
        guard !facts.isAgentRunning else { return .refuse(.agentRunning) }

        // Then the user's own hands, exactly as the rename gate weighs them. A detached HEAD may
        // be holding commits that no ref points at, and a branch switched by hand means the
        // workspace is not where Bloom left it.
        guard let checkedOut = facts.checkedOutBranch else { return .refuse(.detachedHead) }
        guard checkedOut == facts.recordedBranch else {
            return .refuse(.switchedByHand(checkedOut))
        }
        guard checkedOut != facts.baseBranch else {
            return .refuse(.onBaseBranch(checkedOut))
        }

        // Then the repository's own state. `git checkout -b` mid rebase abandons the rebase.
        guard !facts.hasOperationInProgress else { return .refuse(.operationInProgress) }

        let branch = ContinuationBranch.next(
            after: facts.recordedBranch, taken: facts.takenBranches
        )
        guard Git.isValidBranchName(branch), !facts.takenBranches.contains(branch) else {
            return .refuse(.noValidName)
        }
        return .cut(branch: branch)
    }
}

/// What the branch after a merged one is called.
///
/// Bloom normally names a branch from the first prompt, using a model (`WorkspaceNamer`). That is
/// not available here and cannot be: at the moment Continue is pressed the user has not said what
/// the next piece of work is, so there is nothing to name it after. The only honest name available
/// is one derived from the branch that just landed, which is what this does.
///
/// A workspace named after the task that just merged keeps that name, for the same reason. Bloom
/// will not invent a new name for work nobody has described yet, and a name silently replaced with
/// a guess is worse than one that is a little behind. The user renames it in the sidebar when they
/// know what it is now for, and `WorkspaceManager.continueOnNewBranch` leaves both the name and
/// `baseBranch` alone.
public enum ContinuationBranch {
    /// `dark-mode-toggle` becomes `dark-mode-toggle-2`, and `dark-mode-toggle-2` becomes
    /// `dark-mode-toggle-3` rather than `dark-mode-toggle-2-2`.
    ///
    /// The trailing number is only ever stripped when the name without it is a branch that
    /// actually exists. That is what stops `fix-utf-8` from being read as the eighth attempt at
    /// `fix-utf` and continued as `fix-utf-2`: `fix-utf` is not a branch, so `-8` is part of the
    /// name and the answer is `fix-utf-8-2`.
    ///
    /// Any prefix the repository configures comes along untouched, because the whole name is
    /// carried rather than rebuilt: `freek/dark-mode-toggle` continues as
    /// `freek/dark-mode-toggle-2`.
    public static func next(after branch: String, taken: Set<String>) -> String {
        Git.uniqueBranch(stem(of: branch, taken: taken), taken: taken)
    }

    static func stem(of branch: String, taken: Set<String>) -> String {
        guard let separator = branch.lastIndex(of: "-") else { return branch }
        let suffix = branch[branch.index(after: separator)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return branch }

        let stem = String(branch[branch.startIndex..<separator])
        guard !stem.isEmpty, taken.contains(stem) else { return branch }
        return stem
    }
}

/// Where the new branch was actually cut from, which is not always where we wanted it cut from.
public enum ContinuationBase: String, Sendable, Hashable {
    /// `git fetch` worked, so the branch starts at the base as the remote has it right now. The
    /// normal case, and the one that makes continuing worth doing at all.
    case fetched
    /// The remote could not be reached, so the last known `origin/<base>` on this disk was used.
    /// Everything merged since the last fetch is missing from it.
    case cachedRemote
    /// There is no remote-tracking ref at all, so the local base branch was used. A repository
    /// with no remote, which is a perfectly ordinary thing for Bloom to be pointed at.
    case localBranch

    /// One line for the notice, or nothing when there is nothing to warn about.
    public var warning: String? {
        switch self {
        case .fetched:
            nil
        case .cachedRemote:
            "Bloom could not reach the remote, so the new branch starts from the last copy of the "
                + "base branch on this disk. Anything merged since then is not underneath it."
        case .localBranch:
            "There is no remote-tracking copy of the base branch here, so the new branch starts "
                + "from the local one."
        }
    }
}

/// What continuing actually did, for the sentence the inspector shows afterwards.
public struct WorkspaceContinuation: Sendable, Hashable {
    /// The workspace row as it now stands, with its new branch.
    public var workspace: Workspace
    /// The branch that was merged, still on this machine and still holding its commits.
    public var previousBranch: String
    /// The branch the worktree is on now.
    public var branch: String
    /// The commit it was cut at.
    public var revision: String
    public var base: ContinuationBase
    /// Work that was sitting in the worktree uncommitted and came along to the new branch.
    ///
    /// Nothing is stashed, reset or thrown away: `git checkout -b` carries the working tree over
    /// as it stands, and git refuses outright rather than clobbering anything it cannot. So this
    /// is only ever reported, never acted on.
    public var carriedUncommittedWork: Bool

    public init(
        workspace: Workspace,
        previousBranch: String,
        branch: String,
        revision: String,
        base: ContinuationBase,
        carriedUncommittedWork: Bool
    ) {
        self.workspace = workspace
        self.previousBranch = previousBranch
        self.branch = branch
        self.revision = revision
        self.base = base
        self.carriedUncommittedWork = carriedUncommittedWork
    }

    /// The one line the inspector shows when it worked.
    public var sentence: String {
        var text = "\(workspace.name) is on \(branch) now, cut from \(baseDescription)."
        if carriedUncommittedWork {
            text += " Everything that was uncommitted came with it."
        }
        return text
    }

    /// What the `continueAfterMerge` prompt is rendered against.
    ///
    /// Here rather than in the app so the wording the agent is told can be checked without a
    /// store, a worktree or GitHub, the same way `PullRequestPromptContext` is.
    public func promptValues(pullRequest: Int) -> [String: String] {
        [
            PromptRegistry.ContinueAfterMerge.workspace: workspace.name,
            PromptRegistry.ContinueAfterMerge.branch: branch,
            PromptRegistry.ContinueAfterMerge.previousBranch: previousBranch,
            PromptRegistry.ContinueAfterMerge.baseBranch: workspace.baseBranch,
            PromptRegistry.ContinueAfterMerge.pullRequest: String(pullRequest),
        ]
    }

    public func render(template: String, pullRequest: Int) -> PromptRender {
        PromptTemplate.render(template, values: promptValues(pullRequest: pullRequest))
    }

    private var baseDescription: String {
        switch base {
        case .fetched: "an up to date \(workspace.baseBranch)"
        case .cachedRemote: "the last fetched \(workspace.baseBranch)"
        case .localBranch: "the local \(workspace.baseBranch)"
        }
    }
}

public extension WorkspaceManager {
    /// Everything `ContinuationGate` needs, read out of the repository as it stands right now.
    ///
    /// - Parameter isPullRequestMerged: GitHub's own answer. Nothing here can ask: `gh` lives
    ///   above this layer, the same way it does for `archive`.
    /// - Parameter isAgentRunning: whether this app is holding a running agent process for this
    ///   workspace. Git cannot see that either.
    func continuationFacts(
        workspace: Workspace,
        isPullRequestMerged: Bool,
        isAgentRunning: Bool
    ) async throws -> ContinuationFacts {
        async let checkedOut = try? Git.currentBranch(of: workspace.path)
        async let inProgress = Git.hasOperationInProgress(in: workspace.path)
        async let branches = try? Git.branches(of: workspace.path)

        return ContinuationFacts(
            recordedBranch: workspace.branch,
            checkedOutBranch: await checkedOut ?? nil,
            baseBranch: workspace.baseBranch,
            isPullRequestMerged: isPullRequestMerged,
            isAgentRunning: isAgentRunning,
            hasOperationInProgress: await inProgress,
            takenBranches: Set(await branches ?? [])
        )
    }

    /// Cuts `branch` from an updated base and moves this worktree onto it.
    ///
    /// The worktree does not move and is not rebuilt. That is the whole value of continuing: the
    /// directory is warmed up, its dependencies are installed, its `.env` is in place, its dev
    /// servers are on their ports and the agent's session knows the codebase. Archiving and
    /// starting again throws all of that away to get to the same place.
    ///
    /// Fetch, not pull. A pull would try to merge the base into the branch that is checked out,
    /// which is the merged one, and that is both pointless and a way to end up with a merge
    /// commit nobody asked for. What is wanted is the base's current commit and a new branch at
    /// it, which is `fetch` followed by `checkout -b`.
    ///
    /// Uncommitted work comes along untouched. `git checkout -b` carries the working tree over,
    /// and refuses outright if it cannot, so nothing here can silently discard an edit. Nothing
    /// is stashed and nothing is reset: an agent's half-finished file in a merged workspace is
    /// usually the beginning of the next piece of work rather than leftovers from the last.
    ///
    /// The merged branch is left alone. It still exists locally, it still holds its commits, and
    /// archiving the workspace later will offer to delete it exactly as it does today.
    func continueOnNewBranch(
        workspace: Workspace,
        branch: String
    ) async throws -> WorkspaceContinuation {
        let local = try? await Git.localWork(worktree: workspace.path)
        let resolved = try await Git.baseRevision(
            branch: workspace.baseBranch, in: workspace.path
        )

        try await Git.checkoutNewBranch(branch, at: resolved.revision, in: workspace.path)

        // The branch alone: `git checkout -b` ran between the read and here.
        let updated = try await store.update(workspaceID: workspace.id) { $0.branch = branch }
        guard let saved = updated else { throw WorkspaceError.workspaceGone(workspace.name) }
        return WorkspaceContinuation(
            workspace: saved,
            previousBranch: workspace.branch,
            branch: branch,
            revision: resolved.revision,
            base: resolved.base,
            carriedUncommittedWork: local?.hasUncommitted ?? false
        )
    }
}
