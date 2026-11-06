import Foundation

/// Taking up the project's own checkout as a workspace, and taking it up again after an archive.
///
/// **Neither of these touches the folder, and that is all they are for.** `cut` and `open` add a
/// worktree, record its base and copy the project's ignored files into it; every one of those
/// would act on the owner's real checkout here, and `copyFiles` would copy the project's `.env`
/// onto itself. What is left is a row: the path is the project's, the branch is whatever the
/// folder has checked out, and the base is the same branch, which is what makes "All changes"
/// the work not yet committed. See `WorkspaceKind` for the doors that ask about the kind later.
///
/// Both run inside `WorktreeCutQueue`, the same lane as every create and restore in the
/// repository, so the "is there one already" read and the write after it cannot be split by a
/// second create racing the first. The unique index in `Store.migrate` is the belt under that.
extension WorkspaceManager {
    func adoptProjectCheckout(
        id: WorkspaceID, repo: Repo, name: String?, origin: WorkspaceOrigin
    ) async throws -> Workspace {
        let siblings = try await store.workspaces(repoID: repo.id)
        if let existing = WorkspaceKind.liveProjectCheckout(in: repo.id, among: siblings) {
            throw ProjectCheckoutTaken(existing: existing)
        }
        // A detached head has no branch for the row to name, and there is no earlier one to keep
        // yet. Refused rather than recorded as "HEAD", which every branch rule in the app would
        // then read as a branch called HEAD.
        guard let branch = try await Git.currentBranch(of: repo.path) else {
            throw ProjectCheckoutDetached(path: repo.path)
        }

        let workspace = Workspace(
            id: id,
            repoID: repo.id,
            name: name ?? WorkspaceKind.projectCheckoutName,
            branch: branch,
            path: repo.path,
            baseBranch: branch,
            setupState: WorkspaceSetupPolicy.skip.initialState(script: nil),
            sortOrder: try await store.nextWorkspaceSortOrder(repoID: repo.id),
            origin: origin,
            kind: .projectCheckout
        )
        return try await store.upsert(workspace)
    }

    /// An archived project checkout, live again. Only the row moves: the folder never went
    /// anywhere, so there is nothing to rebuild and no setup state to reset.
    func reactivateProjectCheckout(_ workspace: Workspace, repo: Repo) async throws -> Workspace {
        guard FileManager.default.fileExists(atPath: repo.path), await Git.isRepository(repo.path) else {
            throw WorkspaceRestoreRefusal.projectGone(path: repo.path)
        }
        let siblings = try await store.workspaces(repoID: repo.id)
        if let existing = WorkspaceKind.liveProjectCheckout(
            in: repo.id, among: siblings, excluding: workspace.id
        ) {
            throw WorkspaceRestoreRefusal.projectCheckoutTaken(name: existing.name)
        }
        let updated = try await store.update(workspaceID: workspace.id) { $0.reactivate() }
        guard let restored = updated else { throw WorkspaceError.workspaceGone(workspace.name) }
        await bringProjectBack(repo.id)
        return restored
    }
}

/// Thrown when a project already has a live project checkout. Carries the row, because the answer
/// to "work in the project checkout" when there is one is to go to it, or over the bridge to start
/// a chat in it, and both need to know which it is.
public struct ProjectCheckoutTaken: Error, Sendable, Equatable, CustomStringConvertible {
    public let existing: Workspace

    public var description: String {
        "the project already has a project checkout workspace, '\(existing.name)'"
    }
}

/// Thrown when the project's checkout is on no branch.
public struct ProjectCheckoutDetached: Error, Sendable, Equatable, CustomStringConvertible {
    public let path: String

    public var description: String {
        "the project's checkout at \(path) is on no branch (a detached HEAD). Check out a branch "
            + "there first"
    }
}
