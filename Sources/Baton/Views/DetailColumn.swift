import SwiftUI
import BatonCore

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
            }
        }
    }

    @ViewBuilder
    private var workspace: some View {
        if let workspace = app.selectedWorkspace {
            // `existingModel` rather than `model(for:)`: creating one here would mutate observable
            // state during the render pass. The selection setter has already made it.
            if let model = app.existingModel(for: workspace.id) {
                WorkspaceDetailView(model: model)
            } else {
                LoadingView()
            }
        } else {
            HomeView()
        }
    }
}
