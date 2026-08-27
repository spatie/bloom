import SwiftUI
import BloomCore

/// The detail column: whatever the sidebar's selection points at.
///
/// Its own type rather than a `@ViewBuilder` property on `RootView` so the column has a stable
/// structural identity of its own. `RootView` is where the window's toolbar, inspector, sheet,
/// alert and confirmation all live, and every one of those invalidates it; there is no reason for
/// the centre pane to be rebuilt from scratch because an alert was dismissed.
struct DetailColumn: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.isLoaded {
            LoadingView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.windowBackground)
        } else {
            switch app.selection {
            case .home:
                HomeView()
            case .ask:
                AskView()
            case .workspace(let id):
                workspace(id)
            case .subagent(let workspaceID, let subagentID):
                subagent(subagentID, in: workspaceID)
            case .archived(let id):
                archived(id)
            }
        }
    }

    /// A subagent gets the centre column and nothing else.
    ///
    /// Everything outside this column keeps showing the parent workspace, because
    /// `SidebarSelection.subagent` answers `workspaceID` with it: the terminal is still the
    /// worktree's terminal, the diff is still the worktree's diff, and the composer still sends to
    /// the chat that spawned this subagent. What changes is the one pane that was showing a
    /// conversation, which now shows a different conversation. That is the narrowest thing
    /// selecting a subagent could mean, and it is deliberate.
    ///
    /// An unresolvable subagent lands on the parent workspace rather than on Home, which is the
    /// one place in this file that is not Home: the workspace is still there and still selected as
    /// far as every other pane is concerned, so falling back to Home would take the window
    /// somewhere nobody asked to go.
    @ViewBuilder
    private func subagent(_ id: SubagentID, in workspaceID: WorkspaceID) -> some View {
        if let model = app.existingModel(for: workspaceID) {
            SubagentOutputView(model: model, subagentID: id)
        } else {
            workspace(workspaceID)
        }
    }

    /// An archived workspace is a record rather than a destination, so it gets a reader rather
    /// than the centre column. See `ArchivedWorkspaceView`.
    @ViewBuilder
    private func archived(_ id: WorkspaceID) -> some View {
        if let model = app.existingModel(for: id) {
            ArchivedWorkspaceView(model: model)
        } else {
            // Only reachable if the model went away under the selection, which nothing does on
            // purpose. Home is where an unresolvable selection lands everywhere else in this file.
            HomeView()
        }
    }

    /// The selection's id, and never the row it names.
    ///
    /// This used to read `app.selectedWorkspace`, which looks the same and is not: it searches
    /// `app.workspaces`, so this column declared a dependency on the whole list rather than on the
    /// one workspace it draws. Every write to that list then rebuilt the entire centre column, and
    /// the list is written far more often than the selection moves: on arriving at a workspace
    /// with unread work, after every finished turn, and by the diff stat poll every six seconds
    /// for as long as any agent is running. The column was being thrown away and built again for a
    /// changed line count in a row it does not draw.
    ///
    /// `existingModel` reads a dictionary that is outside observation, so it adds no dependency of
    /// its own, and `AppModel` keeps the `Workspace` inside each model up to date. What is left is
    /// a column that rebuilds when the selection moves and at no other time.
    ///
    /// An id with no model is the same case it always was: the selection setter makes the model
    /// for every id that is in the list, so no model means no such workspace, and Home is where an
    /// unresolvable selection lands everywhere else in this file. Before the store has answered,
    /// `body` has already shown `LoadingView` and this is never asked.
    @ViewBuilder
    private func workspace(_ id: WorkspaceID) -> some View {
        // `existingModel` rather than `model(for:)`: creating one here would mutate observable
        // state during the render pass. The selection setter has already made it.
        if let model = app.existingModel(for: id) {
            // Stamps when SwiftUI got round to asking for this column. Reads and writes
            // nothing the app can see, and compiles to one `if` against a `false` unless a
            // probe run turned it on. See `SwitchTrace`.
            let _ = SwitchTrace.mark("column.body", workspace: id)
            CenterColumnView(model: model)
        } else {
            HomeView()
        }
    }
}
