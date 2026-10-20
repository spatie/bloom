import Foundation

/// Moving a workspace's base once it exists, for a branch rebased onto another one after it was
/// created. A base left behind measured the Changes tab, the diff stat and Create PR against the
/// wrong branch: 495 files for a branch that changed 32.
public enum BaseBranchChange {
    /// Every branch this clone knows, local or on the primary remote, less the workspace's own.
    public static func load(repoPath: String, excluding branch: String) async -> [String] {
        // Empty for a workspace with no worktree on this Mac, and git would answer for the
        // process's own directory instead.
        guard !repoPath.isEmpty else { return [] }
        async let local = Git.branches(of: repoPath)
        async let remote = Git.remoteBranches(of: repoPath)
        async let remoteNames = Git.remoteNames(of: repoPath)
        let primary = WorkspaceStartContext.primaryRemoteBranches(
            references: (try? await remote) ?? [], remoteNames: (try? await remoteNames) ?? []
        )
        return options(local: (try? await local) ?? [], remote: primary, excluding: branch)
    }

    static func options(local: [String], remote: [String], excluding branch: String) -> [String] {
        Set(local + remote).subtracting(["", branch])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Writes the base where git keeps it too, as creating the workspace did: `gh pr create`
    /// without `--base` reads `gh-merge-base`, and so does every context resolved without a base.
    public static func record(_ base: String, for workspace: Workspace) async throws {
        let context = try await Git.repositoryContext(in: workspace.path, baseBranch: base, branch: workspace.branch)
        try await Git.recordBase(context, for: workspace.branch, in: workspace.path)
    }

    /// The target of an open pull request, when the stored base has fallen behind it: changed on
    /// the forge, or moved there by GitHub when a stacked base merged. A finished one is history.
    public static func adopted(from pullRequest: PullRequest?, by workspace: Workspace) -> String? {
        guard let pullRequest, pullRequest.isOpen, let base = pullRequest.baseBranch,
              base != workspace.baseBranch, base != workspace.branch,
              Git.isValidBranchName(base) else { return nil }
        return base
    }

    /// `adopted`, once this clone can resolve it. Fetched first, because the diff never fetches
    /// and a target it has never seen would turn the Changes tab into an error.
    ///
    /// Only on the remote the current base resolves to, which is the repository the pull request
    /// was found in: a local `main` tracking `upstream` is another repository's `main`.
    public static func adoptable(from pullRequest: PullRequest?, by workspace: Workspace) async -> String? {
        guard !workspace.path.isEmpty, let base = adopted(from: pullRequest, by: workspace),
              let current = try? await Git.repositoryContext(in: workspace.path, baseBranch: workspace.baseBranch),
              let next = try? await Git.repositoryContext(in: workspace.path, baseBranch: base),
              current.baseRemote == next.baseRemote,
              (try? await Git.baseRevision(branch: base, in: workspace.path)) != nil else { return nil }
        return base
    }

    /// Why `choice` cannot be the base, or nil when it can. Asked against a fresh listing, because
    /// the menu's may be minutes old.
    public static func refusal(of choice: String, branch: String, available: [String]) -> String? {
        if choice == branch {
            return "\(choice) is this workspace's own branch, so there would be nothing to compare."
        }
        if !available.contains(choice) {
            return "\(choice) is not a branch of this repository or of its remote."
        }
        return nil
    }
}
