import Foundation
import BloomCore

/// Forge access and actions shared by the request strip and Checks tab.
extension WorkspaceModel {
    func invalidatePullRequest() {
        cancelPullRequestRefresh()
        WorkspacePullRequests.shared.forget(workspace.id)
    }
    /// Nil when the forge cannot read the runs. An empty list would claim there are no checks.
    func readChecks() async -> [CheckRun]? {
        await GitHubBridge.checks(for: workspace)
    }

    func sendCheckFailure(_ run: CheckRun) async -> String? {
        await checkFailures.send(run, in: self)
    }

    /// GitLab reports its own access through the read, so gh's state says nothing about it.
    var gitHubReadiness: GitHubAvailability.State {
        forge == .gitLab ? .ready : GitHubAvailability.shared.state
    }

    /// Raises the GitLab sign in sheet for this workspace's host, installing glab first if needed.
    func signInToGitLab() async {
        let access = GitHubAvailability.State(await GitLab.access(in: workspace.path))
        guard access != .ready else {
            await refreshPullRequest()
            return
        }
        let host = await GitLab.host(in: workspace.path)
        GitHubSignIn.shared.presentGitLab(directory: workspace.path, host: host, access: access)
    }

    /// gh's readiness, asked afresh, or ready on GitLab. For the Checks tab's poll.
    func checksReadiness() async -> GitHubAvailability.State {
        forge = await ForgeResolver.forge(for: workspace.path)
        return forge == .gitLab ? .ready : await GitHubAvailability.shared.check()
    }

    func continueAfterMerge(_ pullRequest: PullRequest) async -> AppModel.ContinuationOutcome {
        await app.continueAfterMerge(workspace, pullRequest: pullRequest)
    }

    func requestArchive(presenting: @escaping (ArchiveRequest) -> Void) async {
        await app.archive(workspace, presentConfirmation: presenting)
    }

    func confirmArchive(_ request: ArchiveRequest, presenting: @escaping (ArchiveRequest) -> Void) async {
        await app.confirmArchive(request, presentConfirmation: presenting)
    }
}
