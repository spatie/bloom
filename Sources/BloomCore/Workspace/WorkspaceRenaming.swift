import Foundation

/// What the automatic naming actually did to a workspace.
///
/// Carries the refusal rather than swallowing it, because the one thing this feature must never
/// do is move the name and leave the branch behind without saying so.
public struct WorkspaceNamingResult: Sendable, Hashable {
    /// The workspace as it now stands, whether or not anything changed.
    public var workspace: Workspace
    /// The name actually changed, which is the only thing the reveal animation plays for.
    public var didRename: Bool
    /// Why the branch kept its old name, when there is a reason worth telling the user.
    public var branchRefusal: BranchRenameRefusal?

    public init(workspace: Workspace, didRename: Bool, branchRefusal: BranchRenameRefusal? = nil) {
        self.workspace = workspace
        self.didRename = didRename
        self.branchRefusal = branchRefusal
    }

    /// The one sentence the user is shown, or nothing at all.
    public var notice: String? {
        guard didRename, let branchRefusal else { return nil }
        return WorkspaceNaming.branchNotice(
            name: workspace.name,
            branch: workspace.branch,
            refusal: branchRefusal
        )
    }
}

extension WorkspaceManager {
    /// Everything `BranchRenameGate` needs, read out of the repository as it stands right now.
    ///
    /// Read at the moment of deciding rather than at the moment of asking. Between those two
    /// moments the setup script has run, the agent has started and the user has had five seconds
    /// to do whatever they like, and every fact here is one of them.
    public func branchRenameFacts(
        workspace: Workspace,
        desiredBranch: String,
        hasPullRequest: Bool
    ) async throws -> BranchRenameFacts {
        async let checkedOut = try? Git.currentBranch(of: workspace.path)
        async let ahead = try? Git.commitsAhead(base: workspace.baseBranch, in: workspace.path)
        async let upstream = try? Git.upstream(of: workspace.branch, in: workspace.path)
        async let remote = Git.hasRemoteCounterpart(workspace.branch, in: workspace.path)
        async let inProgress = Git.hasOperationInProgress(in: workspace.path)
        async let branches = try? Git.branches(of: workspace.path)

        return BranchRenameFacts(
            recordedBranch: workspace.branch,
            checkedOutBranch: await checkedOut,
            desiredBranch: desiredBranch,
            // A commit count git refused to give is not evidence that there are none. Treating a
            // failed read as "one commit" is the cautious direction: it refuses the rename rather
            // than performing one on a repository nobody could ask a question of.
            commitsAhead: await ahead ?? 1,
            hasUpstream: (await upstream) != nil,
            hasRemoteCounterpart: await remote,
            hasPullRequest: hasPullRequest,
            hasOperationInProgress: await inProgress,
            takenBranches: Set(await branches ?? [])
        )
    }

    /// Applies a suggestion to a workspace that is still wearing the placeholder Bloom gave it.
    ///
    /// The order is not arbitrary. The name is checked first and the branch second, because a
    /// user who has taken the name over has taken the workspace over, and nothing automatic
    /// should touch its branch either. The branch is renamed before the row is written, so a
    /// failed `git branch -m` leaves the row agreeing with the repository rather than pointing at
    /// a branch that does not exist.
    ///
    /// - Parameter placeholder: the exact name Bloom wrote at creation. The rename is abandoned
    ///   unless the stored name is still that string.
    public func applyName(
        _ suggestion: WorkspaceNameSuggestion,
        to workspaceID: WorkspaceID,
        placeholder: String,
        hasPullRequest: Bool
    ) async throws -> WorkspaceNamingResult? {
        // Re-read rather than trusting the value the caller has been holding for five seconds.
        guard let current = try await store.workspace(id: workspaceID) else { return nil }

        guard WorkspaceNaming.mayApplyName(current: current.name, placeholder: placeholder) else {
            return WorkspaceNamingResult(workspace: current, didRename: false)
        }

        var renamed = current
        var refusal: BranchRenameRefusal?

        let facts = try await branchRenameFacts(
            workspace: current,
            desiredBranch: suggestion.branch,
            hasPullRequest: hasPullRequest
        )

        switch BranchRenameGate.decide(facts) {
        case .rename(let branch):
            do {
                try await Git.renameBranch(current.branch, to: branch, in: current.path)
                renamed.branch = branch
            } catch {
                // Git said no after every check said yes. Rare, and survivable: the workspace
                // keeps the branch it has, and the user is told the same way as any other refusal,
                // in git's own words rather than in a reason invented for it.
                refusal = .gitRefused(error.readableMessage)
            }
        case .refuse(let reason):
            refusal = reason
        }

        renamed.name = suggestion.name

        // Re-reading at the top was not enough on its own. The branch rename between there and
        // here is a `git` call, and the whole value written after it carried every other column
        // back to what it was before that call.
        let name = renamed.name
        let branch = renamed.branch
        let saved = try await store.update(workspaceID: workspaceID) {
            $0.name = name
            $0.branch = branch
        }
        guard let saved else { return nil }
        return WorkspaceNamingResult(workspace: saved, didRename: true, branchRefusal: refusal)
    }
}
