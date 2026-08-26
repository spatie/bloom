import Foundation

/// Whether the pull request gh found for a branch is the one this workspace is about.
///
/// gh has no other way of looking one up: `gh pr view <branch>` matches on the branch NAME, and it
/// answers with merged and closed pull requests as readily as with open ones. Branch names are
/// reused constantly, by people and by Bloom itself, which derives one from the task and from a
/// sea. So a brand new workspace called `update-composer-json`, with nothing written in it yet and
/// an agent still on its first turn, was handed pull request #371 from the last time that name was
/// used: the strip said **Merged**, in GitHub's violet, and offered Archive over work that had not
/// started. Nothing about that workspace had ever been pushed anywhere.
///
/// Two facts settle it, and both are already on hand:
///
/// - **What the worktree was checked out from.** `gh pr checkout` writes the pull request into the
///   branch's own git config, so a review workspace can say which one is its without Bloom
///   keeping a second copy of the answer. When that says a number, it is the answer, and a
///   different number is somebody else's pull request wearing the same branch name.
/// - **When the pull request ended.** A pull request cannot have merged before the workspace that
///   produced it existed. This is the cheap half and it is decisive whatever the repository merges
///   with: reachability of the merged head is not, because a merge commit puts that head into the
///   default branch and therefore into every branch cut from it afterwards.
///
/// An open pull request is always accepted. GitHub allows one open pull request per head branch,
/// so an open one matching this branch's name is this branch's.
public enum PullRequestOwnership {
    /// - Parameter startedAt: when the workspace was created. `Workspace.createdAt`.
    /// - Parameter checkedOutAs: the pull request this worktree was checked out from, when git
    ///   records one. See `Git.checkedOutPullRequest`.
    public static func belongs(
        _ pullRequest: PullRequest,
        toWorkspaceStartedAt startedAt: Date,
        checkedOutAs checkedOutNumber: Int?
    ) -> Bool {
        // A worktree that says what it was checked out from has already answered the question,
        // and it outranks the dates: reviewing a pull request that merged last week is a thing
        // people do on purpose, and the strip has to keep saying so.
        if let checkedOutNumber { return pullRequest.number == checkedOutNumber }
        guard let closedAt = pullRequest.closedAt else { return true }
        return closedAt >= startedAt
    }
}

public extension Git {
    /// The pull request this worktree was checked out from, as `gh pr checkout` recorded it.
    ///
    /// `gh pr checkout` sets `branch.<name>.merge` to `refs/pull/<number>/head` for a pull request
    /// it cannot track by branch, which is every fork and, on recent gh, the ordinary case too.
    /// Reading it back costs one `git config` and needs no column of Bloom's own: the association
    /// is written where git already keeps it, by the command that made it.
    ///
    /// Nil for a worktree on a branch of its own, whose `merge` names a branch on the remote.
    static func checkedOutPullRequest(branch: String, worktree: String) async -> Int? {
        guard isValidBranchName(branch) else { return nil }
        guard let result = try? await run(
            ["config", "--get", "branch.\(branch).merge"], in: worktree
        ), result.ok else { return nil }

        let reference = result.trimmed
        let prefix = "refs/pull/"
        let suffix = "/head"
        guard reference.hasPrefix(prefix), reference.hasSuffix(suffix) else { return nil }
        let digits = reference.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

public extension GitHub {
    /// This workspace's pull request, or nil when the one gh found belongs to an earlier life of
    /// the branch name.
    ///
    /// The only door the app and the tools use, so the ownership question is asked once rather
    /// than at each of the four places that wanted an answer. `pullRequest(forBranch:worktree:)`
    /// stays below it as the raw gh call, which is what `WorkspaceCheckoutResolver` and the
    /// tests want.
    static func pullRequest(
        for workspace: Workspace, maxAge: Duration = .zero
    ) async throws -> PullRequest? {
        try await pullRequest(
            for: workspace, onBranch: await headBranch(of: workspace), maxAge: maxAge
        )
    }

    /// The branch to ask gh about, read from the worktree rather than from the row.
    ///
    /// One local `git rev-parse`, which is nothing beside the `gh` call it is correcting, and it
    /// is the difference between finding a pull request the agent opened from a branch it cut
    /// itself and offering a button that opens a second one. See `PullRequestHead`.
    static func headBranch(of workspace: Workspace) async -> String {
        let checkedOut = (try? await Git.currentBranch(of: workspace.path)) ?? nil
        return PullRequestHead.branch(
            recorded: workspace.branch, checkedOut: checkedOut, base: workspace.baseBranch
        )
    }

    private static func pullRequest(
        for workspace: Workspace, onBranch head: String, maxAge: Duration
    ) async throws -> PullRequest? {
        guard let found = try await pullRequest(
            forBranch: head, worktree: workspace.path, maxAge: maxAge
        ) else { return nil }

        let checkedOut = await Git.checkedOutPullRequest(
            branch: head, worktree: workspace.path
        )
        guard PullRequestOwnership.belongs(
            found, toWorkspaceStartedAt: workspace.createdAt, checkedOutAs: checkedOut
        ) else { return nil }
        return found
    }

    /// This workspace's checks, which are the checks of this workspace's pull request.
    ///
    /// The same gate, because they come out of the same `gh pr view`: a rollup drawn for a pull
    /// request that merged before this workspace existed is a green tick over work nobody has run
    /// anything against.
    static func checks(for workspace: Workspace, maxAge: Duration = .zero) async throws -> [CheckRun] {
        // The same branch both times, or the rollup is read for one branch and gated on another.
        let head = await headBranch(of: workspace)
        guard try await pullRequest(for: workspace, onBranch: head, maxAge: maxAge) != nil else {
            return []
        }
        return try await checks(forBranch: head, worktree: workspace.path, maxAge: maxAge)
    }
}
