import SwiftUI
import BloomCore

/// Edit mode: the file itself, editable, with the save guard underneath it.
///
/// The bar along the bottom is not decoration. It is the only place the user finds out that a
/// save was refused because the agent had already rewritten the file, and the only way back from
/// that: reload, look at what the agent did, and redo the edit on top of it.
///
/// A path rather than a `ChangedFile`, because the two ways into a file are the diff of one the
/// agent touched and the worktree tree, and the tree opens files git has never heard of. Editing
/// is a question about bytes on disk either way, so the pane only ever needed the path.
struct FileEditPane<Model: WorkspaceFileReview>: View {
    let model: Model
    /// Relative to the workspace's worktree, the way every path in the inspector is.
    let path: String
    let session: FileEditSession
    /// Called after a save lands, for a pane whose other half is now showing stale text.
    var onSaved: () -> Void = {}

    private var absolutePath: String { (model.workspace.path as NSString).appendingPathComponent(path) }

    var body: some View {
        FileEditorSurface(text: session.binding(for: absolutePath), path: path,
            status: session.status(for: absolutePath), hasContents: session.draft(for: absolutePath) != nil,
            isDirty: session.isDirty(absolutePath), onSave: save,
            onReload: { Task { await session.reload(path: absolutePath) } })
            .task(id: absolutePath) { await session.load(path: absolutePath) }
    }

    /// A save changes the worktree, so the file list's counts and the diff behind this pane are
    /// both stale the moment it lands.
    private func save() {
        Task {
            await session.save(path: absolutePath)
            guard case .saved = session.status(for: absolutePath) else { return }
            // Including whatever the review pane is holding for this file, which is a picture of
            // the bytes that have just been replaced. See `WorkspaceModel.forgetHeldDiff`.
            model.forgetHeldDiff(for: path)
            await model.reloadChanges()
            onSaved()
        }
    }

}
