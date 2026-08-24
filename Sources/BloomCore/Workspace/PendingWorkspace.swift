import Foundation

/// A workspace that has been asked for and does not exist yet.
///
/// **This is the row the sidebar draws while `git worktree add` runs.** Pressing Create used to
/// dismiss the sheet onto a window where nothing happened for two or three seconds: the row cannot
/// appear until `Store.upsert` has written it, and that is the last step of a chain that reads the
/// project's branches, picks a free directory, cuts the worktree and copies the project's files
/// across. On a large checkout the cut alone is most of that wait, and none of it can be made
/// instant. What can be made instant is saying that it is happening.
///
/// It is the mirror of `AppModel.archivingWorkspaceIDs`, which hides a row before the disk work
/// rather than after it, for the same reason and with the same shape: the decision has been made,
/// the user is owed the consequence of it now, and the store catches up when it catches up. See
/// `WorkspaceListReconciliation`, whose header is the argument for both halves.
///
/// # It is deliberately not a `Workspace`
///
/// The obvious move is to write the row to the store early, or to put a half-built `Workspace`
/// into `AppModel.workspaces` and guard the places that would act on it. Both are wrong, and the
/// same sentence rules them out: **a row that says a workspace is live before its worktree exists
/// is the bug at the head of `Store` pointing the other way.** Everything that reads
/// `AppModel.workspaces` is entitled to assume there is a worktree at `path`: the archive, the
/// safety report, Open in Finder, the diff poll, `WorkspaceModel.refreshChanges`. Widening that
/// promise and then guarding every reader is a promise nobody can hold for long.
///
/// So this carries only what a row has to draw, it lives beside the workspaces rather than among
/// them, and there is nothing on it anything could act on. A pending row cannot be selected,
/// dragged, archived or opened, because it is not a workspace and does not pretend to be one.
///
/// # The id is the real one
///
/// `WorkspaceStartRequest` carries the id rather than letting `cut` mint one, so the row drawn
/// while the worktree is being cut and the row drawn afterwards are the same row. That is what
/// makes the swap silent: `RowArrival` is keyed on `WorkspaceID`, so an id it has already seen is
/// not an arrival, and the real row takes the pending one's place without a second settle. Two
/// ids would mean a row fading out and another fading in at the same offset, which is a worse
/// answer than the wait it replaces.
public struct PendingWorkspace: Identifiable, Sendable, Hashable {
    /// The id the stored row will carry. See the note above.
    public var id: WorkspaceID
    /// Which project's block it is drawn in.
    public var repoID: RepoID
    /// What it will be called, worked out by `WorkspaceStartPlan.name` before anything is cut.
    ///
    /// The same call `WorkspaceManager` makes when it builds the row for real, so the name cannot
    /// change as the worktree lands. A placeholder that turned into a different word the instant
    /// the row became real would be the thing `WorkspaceManager.start` already refuses to do when
    /// it decides the codename before the worktree rather than after it.
    public var name: String

    public init(id: WorkspaceID, repoID: RepoID, name: String) {
        self.id = id
        self.repoID = repoID
        self.name = name
    }
}
