import SwiftUI
import BloomCore

/// The one way the notes pane gets onto the screen.
///
/// The same shape as `FileReview`, and for the same reason: a workspace has exactly one note, so
/// every route to it has to land on the one tab rather than open another. The `+` menu is the only
/// route today, and this is here anyway, because the second route is what turns a helper into two
/// slightly different helpers.
@MainActor
enum WorkspaceNotes {
    /// Opens the workspace's notes tab, or brings the one it already has forward.
    ///
    /// `reveal` rather than `select`, so a note already open in one half of a split column is not
    /// dragged into the half the user is typing in. Writing a note beside the conversation it is
    /// about is the arrangement this pane is for.
    static func open(in model: WorkspaceModel) {
        let tab = CenterTabStore.shared.showNotes(workspaceID: model.workspace.id)
        WorkspaceTabsStore.shared.reveal(.tool(tab.id), in: model)
    }
}
