import Foundation

/// Moving a workspace's base once it exists, for a branch rebased onto another one after it was
/// created. A base left behind measured the Changes tab, the diff stat and Create PR against the
/// wrong branch: 495 files for a branch that changed 32.
public enum BaseBranchChange {
    /// Local branches and targets on the workspace's base remote, rather than always origin.
    public static func load(repoPath: String, excluding branch: String, baseBranch: String) async -> [String] {
        // An empty cwd asks git about the app's own directory instead of this workspace.
        guard !repoPath.isEmpty,
              let config = try? await Git.repositoryConfiguration(in: repoPath) else { return [] }
        let current = GitRepositoryContext.resolve(config: config, base: baseBranch, branch: branch)
        async let local = Git.branches(of: repoPath)
        async let remote = Git.remoteBranches(of: repoPath)
        let targets = ((try? await remote) ?? []).compactMap { reference -> String? in
            guard let name = current.baseRemote else { return nil }
            return WorkspaceCheckoutPlan.remoteBranchName(reference, remote: name)
        }
        let localTargets = ((try? await local) ?? []).filter {
            guard let tracking = config["branch.\($0).remote"] else { return true }
            return (tracking == "." ? nil : tracking) == current.baseRemote
        }
        return options(local: localTargets, remote: targets, excluding: branch)
    }

    static func options(local: [String], remote: [String], excluding branch: String) -> [String] {
        Set(local + remote).subtracting(["", branch])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Writes the base where git keeps it too, as creating the workspace did: `gh pr create`
    /// without `--base` reads `gh-merge-base`, and so does every context resolved without a base.
    public static func record(_ base: String, for workspace: Workspace) async throws {
        try Git.validate(branch: base)
        let current = try await Git.repositoryContext(
            in: workspace.path, baseBranch: workspace.baseBranch, branch: workspace.branch
        )
        // A remote-only target has no branch.<target>.remote. Resolving its bare name afresh
        // would silently switch an unpinned upstream workspace back to origin.
        let context = GitRepositoryContext(
            baseBranch: base, baseRemote: current.baseRemote,
            publishBranch: current.publishBranch, publishRemote: current.publishRemote,
            baseRemoteURL: current.baseRemoteURL, publishRemoteURL: current.publishRemoteURL
        )
        try await Git.recordBase(context, for: workspace.branch, in: workspace.path)
        if current.baseRemote == nil {
            // Moving away from a local base tracked with remote "." must keep that choice,
            // even if another remote exists and the new branch has no tracking configuration.
            try await Git.check(
                ["config", "branch.\(workspace.branch).bloom-base-remote", "."], in: workspace.path
            )
        }
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
    /// A local branch with the same name is insufficient when the pull request belongs to a
    /// remote repository. Fetch and resolve on the current base remote explicitly.
    public static func adoptable(from pullRequest: PullRequest?, by workspace: Workspace) async -> String? {
        guard !workspace.path.isEmpty, let base = adopted(from: pullRequest, by: workspace),
              let current = try? await Git.repositoryContext(
                in: workspace.path, baseBranch: workspace.baseBranch, branch: workspace.branch
              ) else { return nil }
        if let remote = current.baseRemote {
            _ = await Git.fetch(base, in: workspace.path, remote: remote)
            guard await Git.revision(of: "refs/remotes/\(remote)/\(base)", in: workspace.path) != nil else {
                return nil
            }
        } else {
            guard await Git.revision(of: "refs/heads/\(base)", in: workspace.path) != nil else { return nil }
        }
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
