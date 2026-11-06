import SwiftUI
import BloomCore

/// The detail column's toolbar. The sidebar draws its own toggle while it is open, grouped with
/// New (see `SidebarView`), so this one draws a toggle only while the sidebar is folded. Search and the inspector use standard toolbar buttons; only the
/// pull request band needs a title-bar accessory to follow the inspector's width.
struct BloomWindowToolbar: ToolbarContent {
    let app: AppModel
    let isSidebarFolded: Bool

    var body: some ToolbarContent {
        if isSidebarFolded {
            ToolbarItem(placement: .navigation) {
                SidebarToggleButton()
            }
        }

        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { app.stepNavigation(by: -1) }
                .disabled(!app.canStepNavigation(by: -1))
                .help("Back to the previous workspace or tab (⌃⇧⇥)")
            Button("Forward", systemImage: "chevron.right") { app.stepNavigation(by: 1) }
                .disabled(!app.canStepNavigation(by: 1))
                .help("Forward to the next workspace or tab (⌃⇥)")
        }

        ToolbarItem(placement: .navigation) {
            WindowTitleControl(app: app)
                .padding(.leading, Metrics.spacingWide)
        }
        // The editable window title is text, so it does not need a button's background.
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible, placement: .navigation)

        ToolbarItem(placement: .primaryAction) {
            Button("Search", systemImage: "magnifyingglass") {
                SearchPanelModel.shared.open(app: app)
            }
            .help("Search workspaces, transcripts and commands")
        }

        // Between Search and the inspector toggle: the inspector toggle keeps the window's edge the
        // way the sidebar toggle keeps the other one, and `+` sits in the middle of the group, as
        // asked for. Only on a workspace: Home and Ask Bloom have no centre column to open a tab
        // in, and a `+` that does nothing there is worse than none.
        // `selectedModel` rather than `selectedWorkspace`, because the menu acts on the model and
        // a model not prepared yet has nothing for it to act on.
        if let workspace = app.selectedModel, app.selectedWorkspace != nil {
            ToolbarItem(placement: .primaryAction) {
                NewTabMenu(model: workspace)
            }
        }
        if case .conversation(let id) = app.selection,
           let state = app.ask.paneState(for: id) {
            ToolbarItem(placement: .primaryAction) {
                ConversationNewTabMenu(state: state)
            }
        }

        if app.isInspectorPresented || app.selectedWorkspace != nil {
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.right") {
                    app.isInspectorVisible.toggle()
                }
                .accessibilityValue(app.isInspectorVisible ? "Shown" : "Hidden")
                .help(app.isInspectorVisible ? "Hide the changed files" : "Show the changed files")
            }
        }
    }
}
