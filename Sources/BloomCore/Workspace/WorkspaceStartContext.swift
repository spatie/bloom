import Foundation
import BloomClient

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
    /// The local branches, and only those: the window also asks this list which names are taken.
    public let branches: [String]
    /// Branches the primary remote has, by their plain name, as this clone last fetched them.
    public let remoteBranches: [String]
    public let settings: RepoSettings
    public let isNamingAvailable: Bool

    public static func load(repoPath: String) async -> WorkspaceStartContext {
        async let local = Git.branches(of: repoPath)
        async let remote = Git.remoteBranches(of: repoPath)
        async let names = Git.remoteNames(of: repoPath)
        return WorkspaceStartContext(
            branches: (try? await local) ?? [],
            remoteBranches: primaryRemoteBranches(
                references: (try? await remote) ?? [], remoteNames: (try? await names) ?? []
            ),
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

    /// The plain names of the branches on the remote a bare base name resolves against.
    ///
    /// Only that remote, and the choice is `GitRepositoryContext.resolve`'s own when nothing is
    /// configured: `origin` if there is one, otherwise the first remote by name. A branch only a
    /// second remote has would be offered here and then looked for on the first, and not found.
    static func primaryRemoteBranches(references: [String], remoteNames: [String]) -> [String] {
        guard let primary = remoteNames.contains("origin") ? "origin" : remoteNames.min() else {
            return []
        }
        return references.compactMap { WorkspaceCheckoutPlan.remoteBranchName($0, remote: primary) }
    }

    /// What a new branch may be cut from: every branch this clone knows of, local or remote.
    ///
    /// The picker used to list local branches alone, so a colleague's branch that had never been
    /// checked out here could be opened from the other tab and not started from on this one. A
    /// base is resolved remote first now, see `WorkspaceManager.startPoint`, so a name that exists
    /// only on `origin` is as good a base as any. One row per name, sorted the way
    /// `WorkspaceCheckoutPlan.offeredBranches` sorts the other tab.
    public static func baseBranchOptions(
        local: [String], remote: [String], defaultBranch: String
    ) -> [String] {
        let names = Set(local + remote).filter { !$0.isEmpty }
        return branchOptions(
            branches: names.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            defaultBranch: defaultBranch
        )
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

public typealias WorkspaceCheckoutOptions = BloomClient.WorkspaceCheckoutOptions

extension WorkspaceCheckoutOptions {
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
        async let remoteNamesRead = Git.remoteNames(of: repoPath)
        let local = (try? await localListing) ?? []
        let remote = (try? await remoteListing) ?? []
        let remoteNames = (try? await remoteNamesRead) ?? []
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
                    pullRequestHeads: WorkspaceCheckoutPlan.heads(of: pullRequests),
                    remoteNames: remoteNames
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
