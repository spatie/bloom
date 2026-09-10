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
