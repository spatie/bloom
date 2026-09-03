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
    /// The branch the merged pull request is for, and therefore the branch this workspace has
    /// finished with.
    ///
    /// GitHub's answer rather than the workspace row's, because the row goes stale and this does
    /// not. A workspace was refused with `switchedByHand` over a merged pull request it had every
    /// right to continue from: `Workspace.branch` said `freekmurze/investigate-problem`, the
    /// worktree was on `freekmurze/fix-stuck-channel-deletions`, and the reflog shows the agent
    /// itself cutting the second from the first fourteen minutes after the workspace was made.
    /// Nothing had gone wrong and nobody had switched anything by hand. The row simply records
    /// where Bloom put the worktree, and an agent that cuts a branch of its own never touches it.
    ///
    /// The strip was already right about this: `PullRequestHead` asks gh about the branch the
    /// worktree is on **now**, which is how it found pull request #381 and drew the Continue
    /// button in the first place. So the refusal named, as the branch the pull request was not
    /// for, the exact branch the pull request was for. The two halves of the same band now read
    /// the same fact.
    public var mergedBranch: String
    /// The branch actually checked out in the worktree, or nil for a detached HEAD.
    public var checkedOutBranch: String?
    /// The branch the finished pull request targeted, and the one the new branch is cut from.
    public var baseBranch: String
    /// GitHub says the pull request for `mergedBranch` was merged. Only ever true when GitHub
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
        mergedBranch: String,
        checkedOutBranch: String?,
        baseBranch: String,
        isPullRequestMerged: Bool = false,
        isAgentRunning: Bool = false,
        hasOperationInProgress: Bool = false,
        takenBranches: Set<String> = []
    ) {
        self.mergedBranch = mergedBranch
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
    /// The worktree is on a branch, and it is not the one the merged pull request was for. Both
    /// names, because the whole content of the refusal is that they differ.
    case switchedByHand(onBranch: String, pullRequestBranch: String)
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
        case .switchedByHand(let branch, let pullRequestBranch):
            "This worktree is on \(branch) now, and the pull request that merged was for "
                + "\(pullRequestBranch). Bloom will not move a checkout off a branch it was not "
                + "the one to put it on."
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

/// Which branch a merged pull request is actually for.
///
/// gh reports the head branch and `PullRequest.branch` carries it, so that is the answer whenever
/// there is one. It is empty from a gh old enough not to report it, and the fallback then is the
/// branch the pull request was looked up under, which is `PullRequestHead`'s decision and is
/// already the live checkout in every case that gets this far. Asking `PullRequestHead` again
/// rather than keeping a second copy of that rule is the point: the branch Continue compares
/// against has to be the branch the pull request was found by, or the strip and the button are
/// answering two different questions again.
public enum ContinuationHead {
    /// - Parameter recorded: `Workspace.branch`.
    /// - Parameter checkedOut: what the worktree says now, or nil for a detached HEAD.
    public static func branch(
        of pullRequest: PullRequest, recorded: String, checkedOut: String?, base: String
    ) -> String {
        let reported = pullRequest.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported.isEmpty else { return reported }
        return PullRequestHead.branch(recorded: recorded, checkedOut: checkedOut, base: base)
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
        // be holding commits that no ref points at, and a worktree standing somewhere other than
        // the branch that merged is a worktree somebody has moved for a reason of their own.
        //
        // Against the pull request's branch rather than against the workspace row, which is the
        // whole of the report on `ContinuationFacts.mergedBranch`: an agent that cuts its own
        // branch leaves the row behind, and comparing with the row refused the one case this
        // feature exists for while letting nothing else through.
        guard let checkedOut = facts.checkedOutBranch else { return .refuse(.detachedHead) }
        // The base first, because it is the more specific description of the same fact. A
        // worktree parked on main is not on the merged branch either, and being told it has been
        // switched away from a branch it never left is a worse sentence than being told there is
        // nothing on main to continue from.
        guard checkedOut != facts.baseBranch else {
            return .refuse(.onBaseBranch(checkedOut))
        }
        guard checkedOut == facts.mergedBranch else {
            return .refuse(
                .switchedByHand(onBranch: checkedOut, pullRequestBranch: facts.mergedBranch)
            )
        }

        // Then the repository's own state. `git checkout -b` mid rebase abandons the rebase.
        guard !facts.hasOperationInProgress else { return .refuse(.operationInProgress) }

        // Named after the branch that merged, which is the branch the worktree is standing on
        // and, since the check above, the same string. Naming from the row would have called the
        // next branch after a name the work stopped using two hours ago.
        let branch = ContinuationBranch.next(after: checkedOut, taken: facts.takenBranches)
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
}

/// What continuing actually did.
///
/// It used to carry the sentence the inspector showed afterwards, a green banner over the file
/// list saying which branch the worktree was on and what it was cut from. The owner asked for it
/// to go: "remove this, we don't need that." What it reported is on screen anyway, in the strip's
/// own branch name and in `ContinuedBranch.line`, so the banner was a third telling.
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

    public init(
        workspace: Workspace,
        previousBranch: String,
        branch: String,
        revision: String,
        base: ContinuationBase
    ) {
        self.workspace = workspace
        self.previousBranch = previousBranch
        self.branch = branch
        self.revision = revision
        self.base = base
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
}

/// The state a workspace is in for the minutes after it continues, and the sentence for it.
///
/// It is a real state and it had no words of its own. There is no pull request, because the one
/// there was has merged and belonged to a branch this worktree has left; there is nothing on the
/// branch, because it was cut from the base a moment ago; and the strip therefore fell back to
/// the line it shows a workspace nobody has done anything in yet, "Nothing has changed on this
/// branch yet.", which is true and reads as though the last two hours never happened.
///
/// Held for a branch name rather than for a workspace, and compared against the branch the strip
/// is drawing. The moment the worktree moves again, by an agent cutting its own branch or by
/// anybody else, this stops describing it and the ordinary line comes back. It lives in memory
/// and does not survive a relaunch, which is right: a day later this is an ordinary empty branch
/// and the merge that made it is history rather than news.
public struct ContinuedBranch: Sendable, Hashable {
    /// The branch that was cut. What the line is checked against.
    public var branch: String
    /// The branch that merged, still on this machine.
    public var previousBranch: String
    public var baseBranch: String
    /// The pull request that merged, or 0 when its number is not known.
    public var pullRequest: Int

    public init(branch: String, previousBranch: String, baseBranch: String, pullRequest: Int) {
        self.branch = branch
        self.previousBranch = previousBranch
        self.baseBranch = baseBranch
        self.pullRequest = pullRequest
    }

    public init(_ continuation: WorkspaceContinuation, pullRequest: Int) {
        self.init(
            branch: continuation.branch,
            previousBranch: continuation.previousBranch,
            baseBranch: continuation.workspace.baseBranch,
            pullRequest: pullRequest
        )
    }

    /// The line under the branch name in the pull request strip, on a branch with nothing on it.
    ///
    /// One row, tail truncated at the inspector's default width, so it says the three things a
    /// reader standing in front of an empty branch needs and stops: where it came from, why it is
    /// empty, and that this is not a workspace that has done nothing.
    ///
    /// The pull request number when there is one, because it is shorter than a branch name and it
    /// is what the reader was looking at ten seconds ago.
    public static func line(on branch: String, continued: ContinuedBranch?) -> String {
        guard let continued, continued.branch == branch else {
            return "Nothing has changed on this branch yet."
        }
        let merged = continued.pullRequest > 0
            ? "#\(continued.pullRequest)"
            : continued.previousBranch
        return "Cut from \(continued.baseBranch) after \(merged) merged. Nothing on it yet."
    }
}

public extension WorkspaceManager {
    /// Everything `ContinuationGate` needs, read out of the repository as it stands right now.
    ///
    /// - Parameter pullRequest: the one the strip is showing, which is GitHub's own answer and
    ///   the reason the button is on screen. Nothing here can ask for it: `gh` lives above this
    ///   layer, the same way it does for `archive`. Nil is a workspace with no pull request at
    ///   all, and the gate refuses it on the merge.
    /// - Parameter isAgentRunning: whether this app is holding a running agent process for this
    ///   workspace. Git cannot see that either.
    func continuationFacts(
        workspace: Workspace,
        pullRequest: PullRequest?,
        isAgentRunning: Bool
    ) async throws -> ContinuationFacts {
        async let checkedOut = try? Git.currentBranch(of: workspace.path)
        async let inProgress = Git.hasOperationInProgress(in: workspace.path)
        async let branches = try? Git.branches(of: workspace.path)

        let live = await checkedOut
        // The row only when there is nothing better. It is what the old comparison used and it is
        // what goes stale, so it is the fallback rather than the source: see `mergedBranch`.
        let merged = pullRequest.map {
            ContinuationHead.branch(
                of: $0, recorded: workspace.branch, checkedOut: live, base: workspace.baseBranch
            )
        }

        return ContinuationFacts(
            mergedBranch: merged ?? workspace.branch,
            checkedOutBranch: live,
            baseBranch: workspace.baseBranch,
            isPullRequestMerged: pullRequest?.isMerged ?? false,
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
        // The branch actually being left, read off the worktree rather than taken from the row,
        // for the reason `ContinuationFacts.mergedBranch` gives at length: the row is where Bloom
        // put this worktree and an agent that cuts a branch of its own does not update it. The
        // prompt the agent is handed names this branch, and naming one the work left hours ago
        // would be worse than saying nothing.
        let leaving = (try? await Git.currentBranch(of: workspace.path)) ?? workspace.branch
        let resolved = try await Git.baseRevision(
            branch: workspace.baseBranch, in: workspace.path
        )

        try await Git.checkoutNewBranch(branch, at: resolved.revision, in: workspace.path)

        // The branch and the pull request it belonged to, and nothing else: `git checkout -b` ran
        // between the read and here.
        //
        // The number goes because the merged pull request was the OLD branch's. Left on the row it
        // would be looked up by number on the next poll, found merged, and drawn over a branch
        // with nothing on it yet, which is the same purple strip and the same dead Squash and
        // merge button the column was added to fix, arriving from the other direction. This is the
        // persisted half of `WorkspacePullRequests.forget`, which the app calls for the cache.
        let updated = try await store.update(workspaceID: workspace.id) {
            $0.branch = branch
            $0.pullRequestNumber = nil
        }
        guard let saved = updated else { throw WorkspaceError.workspaceGone(workspace.name) }
        return WorkspaceContinuation(
            workspace: saved,
            previousBranch: leaving,
            branch: branch,
            revision: resolved.revision,
            base: resolved.base
        )
    }
}
