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
/// terminal panel's on the panel's own strip. The worktree's own menu went the same way and for
/// the same reason: it is in the title bar over the column it describes, in `TitleBarStrip`. What
/// is left is starting work, on the leading edge, and only while the sidebar is folded away. See
/// `isSidebarCollapsed`.
///
/// There is no Refresh Changes either. The changed file list polls every six seconds and redraws
/// itself, so the command could only ever do what had already happened, and a control that does
/// nothing teaches the user that the list is not to be trusted.
struct BloomWindowToolbar: ToolbarContent {
    let app: AppModel

    /// Whether the first column is folded away, which is the only state this toolbar draws
    /// anything in.
    ///
    /// Both halves of the `+` are things the sidebar already offers, in the place they belong: a
    /// project's own row carries the `+` that starts a workspace in it, and the Projects heading
    /// carries the button that adds a project. Those two say WHICH project, which is the question
    /// the toolbar's version has to ask in a sheet, so with the pane on screen the toolbar item
    /// was a third way to reach two controls a few centimetres to its left.
    ///
    /// A collapsed sidebar is the case that is not a duplicate, and it is exactly the case where
    /// the other two are gone: fold the pane away and nothing in the window starts work any more.
    /// Home has a New Workspace button only while there are no workspaces at all, and the centre
    /// column has none. So the control appears when it is the only one left and stands down when
    /// it is not.
    ///
    /// Nothing is only here. New Workspace is Command N in the File menu and Add Project Folder is
    /// Command Shift O beside it, so both keys work in either state, on Home and in a workspace,
    /// whether or not this item is on screen. This is the pointer's way in, not the only way in.
    let isSidebarCollapsed: Bool

    var body: some ToolbarContent {
        if isSidebarCollapsed {
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
                // The control had no accessibility label at all, which matters more now that it
                // is the one pointer route to this in a window with no sidebar. Read back out of
                // the running app's tree: the split button is an `AXPopUpButton` whose label was
                // empty, and it now says this. Its two halves are SwiftUI's own and are not
                // reachable from here: the `+` still answers "add", off the symbol rather than
                // off the `Label`'s words, and the caret answers nothing.
                .accessibilityLabel("Start a workspace")
            }
        }

        // The worktree's menu is not here any more. It was a trailing toolbar item, pinned to the
        // window's own edge, which put it directly above the inspector's pull request strip: two
        // stacked rows in the top right corner, both describing the same workspace. The strip has
        // taken the top row, since it is the one with a state in it, and the menu moved one place
        // left to where the centre column ends. Both now live in `TitleBarStrip`, which is a title
        // bar accessory rather than a toolbar item, because a toolbar item is sized by its content
        // and this band has to be as wide as the pane under it.
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
