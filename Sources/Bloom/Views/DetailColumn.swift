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
            case .workspace:
                workspace
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

    @ViewBuilder
    private var workspace: some View {
        if let workspace = app.selectedWorkspace {
            // `existingModel` rather than `model(for:)`: creating one here would mutate observable
            // state during the render pass. The selection setter has already made it.
            if let model = app.existingModel(for: workspace.id) {
                // Stamps when SwiftUI got round to asking for this column. Reads and writes
                // nothing the app can see, and compiles to one `if` against a `false` unless a
                // probe run turned it on. See `SwitchTrace`.
                let _ = SwitchTrace.mark("column.body", workspace: workspace.id)
                CenterColumnView(model: model)
            } else {
                LoadingView()
            }
        } else {
            HomeView()
        }
    }
}
