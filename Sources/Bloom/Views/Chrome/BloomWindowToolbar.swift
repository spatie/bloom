import SwiftUI
import BloomCore

/// The window toolbar.
///
/// A `ToolbarContent` type rather than a `@ToolbarContentBuilder` property on `RootView`, so the
/// toolbar takes the model as an input rather than reaching for it as ambient environment.
///
/// It is attached to the DETAIL column, never to the `NavigationSplitView`. See `RootView` for the
/// crash that taught us the difference.
///
/// There are no pane toggles here any more. A toolbar item sits above all three columns and so
/// says nothing about which of them it moves, and on macOS 26 a `.button` toggle's on state is a
/// saturated accent fill, which made two permanently-on panes read as two alarms. Both controls
/// now live on the boundary they open: the inspector's on the end of the centre tab strip, the
/// terminal panel's on the panel's own strip. What is left is the one thing that belongs to the
/// window rather than to a pane, which is starting work.
struct BloomWindowToolbar: ToolbarContent {
    let app: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // A split button: the common case is one click, and the folder picker that used to
            // hide in the account row lives behind the arrow.
            Menu {
                Button("New Workspace", action: presentCreate)
                    .disabled(app.repos.isEmpty)
                Button("Add Project Folder\u{2026}", action: addProject)
                Divider()
                Button("Refresh Changes", action: refreshChanges)
            } label: {
                Label("New workspace", systemImage: "plus")
            } primaryAction: {
                if app.repos.isEmpty { addProject() } else { presentCreate() }
            }
            .help("Start a workspace")
        }

        // On macOS 26 every toolbar item is handed its own Liquid Glass background. This one
        // draws its whole content itself, so the system capsule is a second background on top of
        // it: a circle around the single word on Home, and a rim with no clearance around the
        // project swatch and the overflow menu on a workspace.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                WindowTitleLabel()
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                WindowTitleLabel()
            }
        }
    }

    // MARK: - Actions

    /// Every entry point goes through the same notification so the sheet behaves identically
    /// whether it came from the toolbar, the sidebar, Home or the menu bar.
    private func presentCreate() {
        NotificationCenter.default.post(name: .bloomNewWorkspace, object: nil)
    }

    private func addProject() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await app.addRepository(at: path) }
    }

    private func refreshChanges() {
        Task { await app.refreshDiffStats() }
    }
}
