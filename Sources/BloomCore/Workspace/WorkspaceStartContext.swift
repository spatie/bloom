import Foundation

/// What the create window learns about a repository before Create can be pressed: the branches a
/// worktree could be cut from, the repository's settings, and whether a model is around to name
/// the workspace.
///
/// This used to be the last allow-listed exception to the rule that a `View` does not run a
/// subprocess: `CreateWorkspaceView` asked `Git.branches` from its own `.task`, and with the
/// call went the two branch decisions below, where no test could reach them. The gathering is
/// one function so the sheet still makes a single hop off the main actor for all three reads (a
/// branch listing, a settings file chain and a PATH lookup, none of which belongs on the actor
/// drawing a sheet), and the decisions are pure functions so the suite can hold them.
public struct WorkspaceStartContext: Sendable {
    public let branches: [String]
    public let settings: RepoSettings
    public let isNamingAvailable: Bool

    public static func load(repoPath: String) async -> WorkspaceStartContext {
        WorkspaceStartContext(
            branches: (try? await Git.branches(of: repoPath)) ?? [],
            settings: SettingsLoader.load(repo: repoPath),
            isNamingAvailable: WorkspaceNamer.isAvailable
        )
    }

    /// What the base branch picker offers. A repository with no branches yet, or one whose
    /// listing failed, still names its default branch, because a picker with nothing in it reads
    /// as broken rather than new.
    public static func branchOptions(branches: [String], defaultBranch: String) -> [String] {
        branches.isEmpty ? [defaultBranch] : branches
    }

    /// Where the worktree is cut from once the real branch list is in: the current choice if it
    /// survives the listing, else the default branch, else the first branch there is.
    public static func resolvedBaseBranch(
        current: String,
        branches: [String],
        defaultBranch: String
    ) -> String {
        if branches.contains(current) { return current }
        if branches.contains(defaultBranch) { return defaultBranch }
        return branches.first ?? defaultBranch
    }
}

/// What the create window can offer to open, as opposed to what it can cut a branch from.
///
/// Loaded separately from `WorkspaceStartContext` and after it, because listing pull requests is a
/// network call: the sheet has to be typeable the moment it opens, and a project whose GitHub is
/// slow or unreachable must delay the picker rather than the composer.
public struct WorkspaceCheckoutOptions: Sendable {
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

    /// Both branch listings are read here rather than handed in.
    ///
    /// The local half used to arrive from the create window, which loaded it in a task of its own,
    /// and the two tasks raced: this one read the sheet's list before the other had written it, so
    /// on every open the local half was empty. A branch that had never been pushed was missing
    /// from the picker altogether, and one that existed on both sides was offered as "(remote)"
    /// and then checked out with `--track -b`, which git refuses when the local branch is already
    /// there. Reading it here costs one `for-each-ref`, which is what the sheet was paying anyway,
    /// and it runs beside the remote listing rather than after it.
    ///
    /// **Which branches are taken is asked of git here, once per open of the sheet.**
    ///
    /// `git worktree list --porcelain` is one process over a repository with twenty-two worktrees
    /// on it, which is nothing next to the two branch listings and the gh call already in this
    /// function, and it is deliberately here rather than anywhere nearer the picker: the ranking
    /// runs on every keystroke and must stay pure. The answer is folded into the rows and kept
    /// whole in `holders`, so nothing later has to ask again.
    ///
    /// `workspaces` supplies the names. Git says a branch is held and by which folder; only the
    /// database can say that the folder is a Bloom workspace called Quiet Harbour. Passed as rows
    /// rather than as a prepared dictionary so the filtering is `BranchHolder.names`, in the core,
    /// where the suite reaches it. See `BranchHolder`.
    public static func load(
        repoPath: String,
        repoID: RepoID,
        defaultBranch: String,
        workspaces: [Workspace] = []
    ) async -> WorkspaceCheckoutOptions {
        async let localListing = Git.branches(of: repoPath)
        async let remoteListing = Git.remoteBranches(of: repoPath)
        async let worktreeListing = Git.worktrees(of: repoPath)
        let local = (try? await localListing) ?? []
        let remote = (try? await remoteListing) ?? []
        let branchesInUse = BranchHolder.byBranch(
            worktrees: (try? await worktreeListing) ?? [],
            projectPath: repoPath,
            workspaceNames: BranchHolder.names(of: workspaces, in: repoID)
        )

        func options(
            pullRequests: [PullRequestListing] = [],
            access: GitHubAccess = .ready,
            failure: String? = nil
        ) -> WorkspaceCheckoutOptions {
            WorkspaceCheckoutOptions(
                pullRequests: pullRequests,
                branches: WorkspaceCheckoutPlan.offeredBranches(
                    local: local,
                    remote: remote,
                    defaultBranch: defaultBranch,
                    inUse: branchesInUse,
                    pullRequestHeads: WorkspaceCheckoutPlan.heads(of: pullRequests)
                ),
                access: access,
                failure: failure,
                holders: branchesInUse
            )
        }

        let access = await GitHub.access()
        guard access == .ready else { return options(access: access) }

        do {
            return options(pullRequests: try await GitHub.openPullRequests(repoPath: repoPath))
        } catch {
            return options(failure: error.readableMessage)
        }
    }
}
