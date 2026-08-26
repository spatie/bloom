import Foundation

/// Where a workspace an agent asked for starts: a fresh branch cut from one, or a branch that
/// already exists carried on.
///
/// **The choice is the create sheet's, and it is reused rather than restated.** The sheet puts it
/// in a tab strip, `WorkspaceSourceTab`: "Create new branch", where commits land on a new branch
/// and merge into the branch you picked, and "Continue on existing branch", where they land on the
/// branch you picked and merge when it does. Over the bridge the same choice is two arguments, and
/// everything below is the translation between them. The verbs, the sentence each one carries, the
/// merging of the local and remote listings (`WorkspaceCheckoutPlan`), what is already sitting on a
/// branch (`BranchHolder`) and the value `WorkspaceManager` is finally handed (`WorkspaceCheckout`)
/// all come from there, so the two doors cannot come to describe the same choice differently.
///
/// **Why the bridge needed the second verb at all.** `workspace_start` could only cut, so an agent
/// asked to look at a colleague's branch got a fresh branch off its tip: the worktree opened
/// identical to that branch, the Changes tab drew nothing, and the workspace was right about the
/// diff and useless for the job. That is the bug `docs/start-from.html` was written about, arriving
/// a second time through the other door.
///
/// **A pull request is not offered here, and that is a decision.** The sheet's second tab lists
/// them beside the branches, but resolving one costs a `gh` call and a network round trip on a
/// path that so far spends only local git, and an agent that wants a pull request's code can name
/// its head branch, which is what the picker draws a listed pull request by anyway. The case is
/// already carried by `WorkspaceCheckout`, so the day it is wanted it is an argument rather than a
/// mechanism.
public enum AgentStartSource: Sendable, Hashable {
    /// Cut a fresh branch off a named ref. Nil is the project's default branch, which is what a
    /// call that says nothing gets and what this tool did before there was a choice at all.
    case newBranch(from: String?)
    /// Carry on a branch somebody has already written on.
    case existingBranch(ExistingBranch)

    /// Which of the sheet's two tabs this is. The tool's description is written out of these, so
    /// an agent reading the tool list and a person reading the tab strip are told the same thing.
    public var tab: WorkspaceSourceTab {
        switch self {
        case .newBranch: .newBranch
        case .existingBranch: .existingBranch
        }
    }

    /// What the worktree is cut from, for `WorkspaceStartRequest.baseBranch`. Nil for a checkout,
    /// which brings its own base along with it. See `WorkspaceCheckout.baseBranch(default:)`.
    public var baseBranch: String? {
        switch self {
        case .newBranch(let ref): ref
        case .existingBranch: nil
        }
    }

    /// The existing head to open, for `WorkspaceStartRequest.checkout`, or nil for the ordinary
    /// route Bloom has always had.
    public var checkout: WorkspaceCheckout? {
        switch self {
        case .newBranch: nil
        case .existingBranch(let branch): .branch(branch)
        }
    }

    /// Whichever branch this call actually named, or nil when it named none.
    ///
    /// What a failed start is diagnosed against: `WorkspaceStartTrouble.diagnose` asks the
    /// repository about one branch, and it has to be the one the caller wrote down, or a call that
    /// named an existing branch would be answered with a sentence about the default.
    public var namedBranch: String? {
        switch self {
        case .newBranch(let ref): ref
        case .existingBranch(let branch): branch.name
        }
    }

    /// This source's share of the spawn digest, which is what makes a retry of a call the same
    /// call. See `AgentWorkspaceOrder.spawnID`.
    ///
    /// **A new branch contributes exactly what `base_branch` alone used to contribute**, one
    /// element holding the ref or the empty string, and that is not tidiness: spawn ids are stored
    /// on workspace rows, so a call made before this argument existed has to digest the same way
    /// afterwards or its retry cuts a second worktree. The other verb adds an element of its own,
    /// so "a new branch from x" and "carry on x" can never come out as one call.
    var digestMaterial: [String] {
        switch self {
        case .newBranch(let ref): [ref ?? ""]
        case .existingBranch(let branch): ["", "on\u{0}" + branch.name]
        }
    }
}

/// What the two arguments name, read before the repository has been asked anything.
///
/// Separate from `AgentStartSource` because only one of the two verbs costs a subprocess: a call
/// that says nothing, which is nearly all of them, is answered here and never touches git.
public enum AgentStartRequest: Sendable, Equatable {
    case newBranch(from: String?)
    /// The name as the caller wrote it. Nothing has been looked up yet.
    case existingBranch(String)
    case refused(String)

    /// Which verb `base_branch` and `existing_branch` name between them.
    ///
    /// Naming both is refused rather than resolved to whichever was read first. They are one
    /// keystroke apart in intent and opposite in effect, which is the whole reason the sheet draws
    /// them as two tabs, and a call that asked for both has not decided which it wants.
    public static func read(baseBranch: String?, existingBranch: String?) -> AgentStartRequest {
        switch (baseBranch, existingBranch) {
        case let (base?, existing?):
            return .refused(
                "workspace_start takes base_branch or existing_branch, and this call named both: "
                    + "'\(base)' and '\(existing)'. base_branch cuts a new branch from the branch "
                    + "you name, and your commits merge back into it. existing_branch puts the "
                    + "workspace on the branch you name, and your commits land on that branch "
                    + "itself. Ask again with the one you meant."
            )
        case let (_, existing?):
            return .existingBranch(existing)
        case let (base, nil):
            return .newBranch(from: base)
        }
    }
}

/// The branch an `existing_branch` argument named, found in the project it was named in.
///
/// The refusals are the point. A caller with no screen cannot see the picker's list, so being told
/// that a branch is not there, or that something else is already sitting on it, is the difference
/// between asking again correctly and a workspace on a branch nobody meant.
public enum AgentStartBranch: Sendable, Equatable {
    case found(ExistingBranch)
    case refused(String)

    /// Every branch of a project, with whatever is already holding each one.
    ///
    /// Three git reads and one database read, spent only when a call names an existing branch.
    /// `WorkspaceCheckoutPlan.everyBranch` merges the two listings the way the picker merges them,
    /// and `BranchHolder.byBranch` answers what has each one, git's own worktrees included, which
    /// is what lets a branch another tool is sitting on be refused in words rather than by git
    /// exiting 128 half way through a start.
    public static func listing(of repo: Repo, store: Store) async -> [ExistingBranch] {
        async let local = Git.branches(of: repo.path)
        async let remote = Git.remoteBranches(of: repo.path)
        async let worktrees = Git.worktrees(of: repo.path)

        let holders = BranchHolder.byBranch(
            worktrees: (try? await worktrees) ?? [],
            projectPath: repo.path,
            workspaceNames: BranchHolder.names(
                of: (try? await store.workspaces(repoID: repo.id)) ?? [], in: repo.id
            )
        )
        return WorkspaceCheckoutPlan.everyBranch(
            local: (try? await local) ?? [], remote: (try? await remote) ?? [], inUse: holders
        )
    }

    /// The branch of that name, or the sentence saying why there is not one to open.
    ///
    /// `origin/x` resolves to `x`, because a model that has just run `git branch -r` in the
    /// worktree it is standing in will write the name git printed, and refusing that would be
    /// refusing the right branch over a prefix Bloom strips everywhere else anyway.
    ///
    /// The match is exact otherwise. Branch names are case sensitive to git, and a repository with
    /// both `Release` and `release` in it is a repository where guessing puts a workspace on the
    /// wrong one.
    public static func find(
        _ name: String, among branches: [ExistingBranch], project: String
    ) -> AgentStartBranch {
        let wanted = WorkspaceCheckoutPlan.remoteBranchName(name) ?? name

        if let branch = branches.first(where: { $0.name == wanted }) {
            guard let holder = branch.inUseBy else { return .found(branch) }
            return .refused(holder.agentRefusal(branch: branch.name))
        }

        guard !branches.isEmpty else {
            return .refused(
                "Bloom found no branches in the project '\(project)' to continue on. It may have "
                    + "no commits yet, or Bloom may no longer be able to read the repository. "
                    + "Leave existing_branch out to have Bloom cut a new branch, which says what "
                    + "is wrong if it cannot."
            )
        }

        return .refused(
            "The project '\(project)' has no branch called '\(name)', locally or on the remote. "
                + "It has " + BridgeProjectLookup.listing(branches.map(\.name)) + ". Ask again "
                + "with one of those as existing_branch, or leave existing_branch out to cut a "
                + "new branch from the project's default branch."
        )
    }
}
