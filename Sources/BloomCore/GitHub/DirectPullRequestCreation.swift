import Foundation

/// Commits and publishes a workspace branch before asking the forge to open its pull request.
/// Each step is explicit so a failure leaves the completed git work in place and reports it.
public enum DirectPullRequestCreation {
    public static func create(for workspace: Workspace, forge: Forge = .gitHub) async throws -> PullRequest {
        let client = ForgeResolver.client(of: forge)
        let worktree = workspace.path
        guard try await Git.currentBranch(of: worktree) == workspace.branch else {
            throw GitHubError("This worktree is no longer on \(workspace.branch).")
        }
        guard Git.isValidBranchName(workspace.baseBranch) else {
            throw GitHubError("The target branch is not a valid Git branch name.")
        }

        switch await client.readPullRequest(for: workspace, maxAge: .zero) {
        case .current(.some(let existing)):
            throw GitHubError("\(forge.titledRequest) \(forge.reference(existing.number)) already exists for this branch.")
        case .current(nil):
            break
        case .unavailable(let failure):
            throw GitHubError(failure.message)
        }

        let title = Git.title(from: workspace.name, maxLength: 72)
        let local = try await Git.localWork(worktree: worktree)
        if local.hasUncommitted {
            try await Git.stageAll(in: worktree)
            guard !((try await Git.stagedPaths(in: worktree)).isEmpty) else {
                throw GitHubError("There are no changes to commit after applying this repository's ignore rules.")
            }
            // Respect the repository's signing configuration. A failed commit leaves the index
            // staged so the owner can resolve it without losing the selected files.
            do {
                try await Git.check(["commit", "--message", title], in: worktree)
            } catch {
                throw GitHubError("Changes were staged, but the commit failed: \(error)")
            }
        }

        do {
            if forge == .gitLab { try await GitLab.routePushes(of: workspace.branch, in: worktree) }
            try await GitHub.push(
                worktree: worktree, branch: workspace.branch, setUpstream: !local.hasUpstream
            )
        } catch {
            let prefix = local.hasUncommitted
                ? "Changes were committed locally, but the push failed: "
                : "The push failed: "
            throw GitHubError(prefix + String(describing: error))
        }
        do {
            return try await client.createPullRequestFromCommits(
                worktree: worktree, base: workspace.baseBranch, title: title
            )
        } catch {
            throw GitHubError("The branch was pushed, but \(forge.name) did not create the \(forge.request): \(error)")
        }
    }
}
