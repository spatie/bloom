import Foundation

/// What the create sheet learns about a repository before Create can be pressed: the branches a
/// worktree could be cut from, the repository's settings, and whether a model is around to name
/// the workspace.
///
/// This used to be the last allow-listed exception to the rule that a `View` does not run a
/// subprocess: `CreateWorkspaceSheet` asked `Git.branches` from its own `.task`, and with the
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
