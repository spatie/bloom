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
/// terminal panel's on the panel's own strip. What is left is starting work, on the leading edge,
/// and which project you are in, on the trailing one.
///
/// There is no Refresh Changes either. The changed file list polls every six seconds and redraws
/// itself, so the command could only ever do what had already happened, and a control that does
/// nothing teaches the user that the list is not to be trusted.
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
            } label: {
                Label("New workspace", systemImage: "plus")
            } primaryAction: {
                if app.repos.isEmpty { addProject() } else { presentCreate() }
            }
            .help("Start a workspace")
        }

        // Trailing, not principal.
        //
        // Principal placement drops an item next to the window title, which put the project mark
        // and its menu in the middle of the toolbar, over the transcript, a few millimetres from
        // the workspace name it was already sitting beside. It reads as a second title. Every
        // other Mac app puts the thing you are signed in as, or working under, at the far right
        // of the toolbar, and that is also where it lines up with the inspector below it: the
        // project the changes belong to, directly above the changes.
        //
        // On macOS 26 every toolbar item is handed its own Liquid Glass background. This one
        // draws its whole content itself, so the system capsule is a second background on top of
        // it: a circle around the single word on Home, and a rim with no clearance around the
        // project swatch and the overflow menu on a workspace.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                WindowTitleLabel()
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
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
        Task { await app.addProjectByAsking() }
    }
}
