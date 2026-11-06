import Foundation

extension GitLab {
    /// glab writes a fork's URL and original branch into the local alias's tracking config.
    /// Using origin or the local name would update a different branch after the server rebase.
    private static func sourceRemote(for request: PullRequest, worktree: String) async throws -> String {
        guard let branch = try await Git.currentBranch(of: worktree) else {
            throw GitHubError("Check out the merge request's branch first.")
        }
        let config = try await Git.repositoryConfiguration(in: worktree)
        guard config["branch.\(branch).merge"] == "refs/heads/\(request.branch)",
              let remote = config["branch.\(branch).remote"], remote != ".",
              let project = GitLabProject(remote: config["remote.\(remote).url"] ?? remote),
              project.host == GitHub.repositoryHost(request.url) else {
            throw GitHubError("Configure this checkout to track the merge request's source branch before continuing.")
        }
        return remote
    }

    public static func rebasePrompt(_ request: PullRequest, worktree: String) async throws -> String {
        guard let project = await project(in: worktree) else {
            throw GitHubError("This repository has no GitLab remote Bloom can read.")
        }
        try validateIdentity(request, in: project)
        let remote = try await sourceRemote(for: request, worktree: worktree)
        let rebase = TerminalLaunchScript.command(
            executable: "glab", arguments: ["mr", "rebase", String(request.number), "-R", project.webURL]
        )
        let pull = TerminalLaunchScript.command(
            executable: "git", arguments: ["pull", "--rebase", "--", remote, "refs/heads/\(request.branch)"]
        )
        return "Rebase merge request !\(request.number) onto \(request.baseBranch ?? "its target branch"). "
            + "Run `\(rebase)` and wait for it to finish, then update this checkout with `\(pull)`. "
            + "If GitLab or git reports a conflict, stop and say so. Do not merge and do not force push."
    }

    public static func mergeContext(_ request: PullRequest, method: GitHub.MergeMethod, worktree: String) async throws -> String {
        guard let project = await project(in: worktree) else {
            throw GitHubError("This repository has no GitLab remote Bloom can read.")
        }
        try validateIdentity(request, in: project)
        try await validateMergeMethod(request, method: method, worktree: worktree)
        let remote = try await sourceRemote(for: request, worktree: worktree)
        let repository = TerminalLaunchScript.command(executable: "glab", arguments: ["mr", "view", String(request.number), "-R", project.webURL])
        let deletion = TerminalLaunchScript.command(executable: "git", arguments: ["push", "--delete", "--", remote, "refs/heads/\(request.branch)"])
        return "The merge request is at \(request.url). Read it with `\(repository)` and pass the same -R project URL "
            + "to every glab merge or rebase command. If deleting the source branch after merging, use `\(deletion)`."
    }
}
