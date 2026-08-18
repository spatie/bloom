import SwiftUI
import BatonCore

/// The window toolbar.
///
/// A `ToolbarContent` type rather than a `@ToolbarContentBuilder` property on `RootView`. The
/// builder had to open with a local `@Bindable var app = app` to get at the two toggles, which is
/// the tell that the toolbar wanted the model as an input rather than as ambient environment. Here
/// it is handed one, and the toggles bind straight to it.
///
/// It is attached to the DETAIL column, never to the `NavigationSplitView`. See `RootView` for the
/// crash that taught us the difference.
struct BatonWindowToolbar: ToolbarContent {
    @Bindable var app: AppModel

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
        // project swatch and the branch chip on a workspace.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                WindowTitleLabel()
            }
            .sharedBackgroundVisibility(.hidden)

            // Adjacent items share one glass capsule, and a toggle inside a shared capsule has to
            // paint its own "on" fill inside it. With two panel symbols, both usually on, that
            // reads as a filled rectangle inside a rounded fill inside a pill. A spacer gives each
            // toggle a capsule of its own, where being on tints that capsule instead.
            ToolbarItem(placement: .primaryAction) {
                bottomPanelToggle
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                inspectorToggle
            }
        } else {
            ToolbarItem(placement: .principal) {
                WindowTitleLabel()
            }

            ToolbarItemGroup(placement: .primaryAction) {
                bottomPanelToggle
                inspectorToggle
            }
        }
    }

    // MARK: - Toggles
    //
    // Shared by both branches above, which differ only in how the toolbar groups them.

    private var bottomPanelToggle: some View {
        Toggle(isOn: $app.isBottomPanelVisible) {
            Label("Terminal panel", systemImage: "rectangle.bottomthird.inset.filled")
        }
        .toggleStyle(.button)
        .disabled(app.selectedModel == nil)
        .help("Show the terminal panel")
    }

    private var inspectorToggle: some View {
        Toggle(isOn: $app.isInspectorVisible) {
            Label("Inspector", systemImage: "sidebar.right")
        }
        .toggleStyle(.button)
        .disabled(app.selectedModel == nil)
        .help("Show the changed files")
    }

    // MARK: - Actions

    /// Every entry point goes through the same notification so the sheet behaves identically
    /// whether it came from the toolbar, the sidebar, Home or the menu bar.
    private func presentCreate() {
        NotificationCenter.default.post(name: .batonNewWorkspace, object: nil)
    }

    private func addProject() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await app.addRepository(at: path) }
    }

    private func refreshChanges() {
        Task { await app.refreshDiffStats() }
    }
}
