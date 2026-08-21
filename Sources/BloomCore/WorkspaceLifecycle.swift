import Foundation

/// The two moves a workspace's own `state` makes, and the columns that have to move with each.
///
/// **This is deliberately not a state machine, and that is the finding rather than an omission.**
/// `WorkspaceState` has two cases and two events, both transitions are legal, and there are exactly
/// two writers of the column in the whole tree: the archive and the restore. A transition table
/// over that would have no illegal edges to forbid, so it would be a table written for the
/// symmetry of having one, and a rule that forbids nothing teaches nothing.
///
/// What this state did need was the other half of the same problem. Writing `archived` into the
/// column is not archiving. Archiving is removing the worktree from disk and then saying so, and a
/// row that says a workspace is live after its worktree has gone is the bug written into
/// `CLAUDE.md`: it does not heal, and it is still there after a relaunch. Restoring is worse,
/// because the row it hands back
/// is an old workspace's row on a fresh checkout: commit `e2025f3` is a restored workspace whose
/// `setupState` still said `succeeded` about a directory that had been deleted months earlier, so
/// it looked ready, had no dependencies installed, and nothing anywhere said otherwise.
///
/// So both changes are one statement each, here, where the columns cannot be separated. The
/// out-of-process half stays in `WorkspaceManager.archive` and `WorkspaceManager.restore`, which
/// are the one owner of each and the only callers of these two methods.
public extension Workspace {
    /// The worktree is gone. Say so.
    ///
    /// `archivedAt` is not a second chore. It is what the Home list sorts by and what tells an
    /// archived workspace apart from one that was never anything, and `archived` without it is a
    /// row that is in the list and nowhere in it. Set in the same statement as the state, so there
    /// is no version of this that does half of it.
    ///
    /// Says nothing about whether the directory is really gone: that is `WorkspaceManager.archive`,
    /// which does the removal first and calls this after it. The order is the whole point. A row
    /// marked archived over a worktree still on disk is recoverable; a worktree removed under a row
    /// that still says the workspace is live is the bug above.
    mutating func archive(at date: Date = Date()) {
        state = .archived
        archivedAt = date
    }

    /// The worktree was cut again from the branch. Say what came back and what did not.
    ///
    /// Four columns, and the fourth is the one this method exists for. What comes back is
    /// everything git tracks plus everything `files_to_copy` names, and that is not `node_modules`,
    /// not `vendor`, not a built binary and not a local database, because none of those is in
    /// either list. So the setup state has to be told, and telling it is `SetupEvent.worktreeRebuilt`,
    /// which is legal from every state for exactly this reason: the row does not get a vote on what
    /// is on disk.
    ///
    /// `path` is a parameter because a restore does not always land where it started. The old
    /// directory can have been taken by something else in the meantime, and `WorktreePath.free`
    /// picks the next free one, so the row has to be told where the worktree actually is.
    mutating func restore(to path: String, hasSetupScript: Bool) {
        state = .active
        archivedAt = nil
        self.path = path
        apply(.worktreeRebuilt(hasSetupScript: hasSetupScript))
    }
}
