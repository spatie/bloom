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
        } else {
            switch app.selection {
            case .home:
                HomeView()
            case .search:
                SearchView()
            case .workspace(let id):
                workspace(id)
            case .archived(let id):
                archived(id)
            }
        }
    }

    /// An archived workspace is a record rather than a destination, so it gets a reader rather
    /// than the centre column. See `ArchivedWorkspaceView`.
    @ViewBuilder
    private func archived(_ id: String) -> some View {
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
    /// unresolvable selection lands everywhere else in this file. Before the store has answered
    /// there is no list to be missing from, so that case waits instead.
    @ViewBuilder
    private func workspace(_ id: String) -> some View {
        // `existingModel` rather than `model(for:)`: creating one here would mutate observable
        // state during the render pass. The selection setter has already made it.
        if let model = app.existingModel(for: id) {
            // Stamps when SwiftUI got round to asking for this column. Reads and writes
            // nothing the app can see, and compiles to one `if` against a `false` unless a
            // probe run turned it on. See `SwitchTrace`.
            let _ = SwitchTrace.mark("column.body", workspace: id)
            CenterColumnView(model: model)
        } else if app.isLoaded {
            HomeView()
        } else {
            LoadingView()
        }
    }
}
