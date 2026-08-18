import Foundation

/// Why a restore was refused, in the words a user would need to hear.
public enum WorkspaceRestoreRefusal: Error, CustomStringConvertible, Sendable {
    /// Something is already sitting at the worktree path. Writing over it is not a restore.
    case pathInUse(String)
    /// The branch is gone, so the commits it held are no longer reachable by name and the worktree
    /// cannot be recreated from anything.
    case branchMissing(String)

    public var description: String {
        switch self {
        case .pathInUse(let path): "\(path) already exists"
        case .branchMissing(let branch): "the branch \(branch) no longer exists"
        }
    }
}

/// Whether an archive left the workspace rebuildable, which is a narrower question than
/// `WorkspaceSafetyReport.isSafeToDiscard` asks and a different one.
///
/// `isSafeToDiscard` weighs the commits, because deleting the branch as well would make them
/// unreachable. Removing only the worktree does not touch them: the branch is what holds them, and
/// a branch that still exists can be checked out again with every commit in place. So commits are
/// not counted here.
///
/// What is counted is everything git was not keeping a copy of, because that lives in the worktree
/// directory and nowhere else. Once `git worktree remove` has deleted the directory there is no
/// second copy to check out.
public extension WorkspaceSafetyReport {
    var isRestorableFromBranch: Bool {
        !hasUncommittedChanges
            && untrackedFiles.isEmpty
            && modifiedIgnoredFiles.isEmpty
            && detachedCommits == 0
    }
}

/// Putting an archived workspace back.
///
/// This is only ever honest for the archive that kept the branch. Removing a worktree while the
/// branch survives throws away nothing that git was tracking: every commit is still on the branch,
/// so checking the branch out again at the same path rebuilds the same tree. Everything else an
/// archive can destroy (uncommitted edits, untracked files, modified ignored files, commits on a
/// detached HEAD) is gone for good, which is exactly what `WorkspaceSafetyReport` lists before the
/// archive happens. So the caller must only offer this for an archive that report cleared.
///
/// Deliberately not called "unarchive": it restores what git can restore and says so, rather than
/// implying the workspace comes back exactly as it was.
public extension WorkspaceManager {
    /// Whether the worktree could be rebuilt right now. Asked before an undo is offered, so the
    /// app never promises one it cannot carry out.
    func canRestore(workspace: Workspace, repo: Repo) async -> Bool {
        guard !FileManager.default.fileExists(atPath: workspace.path) else { return false }
        return await Git.branchExists(workspace.branch, in: repo.path)
    }

    /// Recreates the worktree at its old path, on its own branch, and marks the workspace active
    /// again.
    ///
    /// The copied files come back too. `createWorkspace` copies `files_to_copy` (`.env*` by
    /// default) into every new worktree, and those are ignored files that git will not restore,
    /// so a restore without this step would hand back a worktree missing the environment the
    /// workspace was set up with.
    @discardableResult
    func restore(workspace: Workspace, repo: Repo) async throws -> Workspace {
        guard !FileManager.default.fileExists(atPath: workspace.path) else {
            throw WorkspaceRestoreRefusal.pathInUse(workspace.path)
        }
        guard await Git.branchExists(workspace.branch, in: repo.path) else {
            throw WorkspaceRestoreRefusal.branchMissing(workspace.branch)
        }

        // The base is only consulted when the branch has to be created, and it exists, so this
        // checks the branch out rather than branching from anything.
        try await Git.addWorktree(
            repo: repo.path,
            path: workspace.path,
            branch: workspace.branch,
            base: workspace.baseBranch
        )

        let settings = SettingsLoader.load(repo: repo.path)
        try copyFiles(settings.filesToCopy, from: repo.path, to: workspace.path)

        return try await store.upsert(workspace.with {
            $0.state = .active
            $0.archivedAt = nil
        })
    }
}
