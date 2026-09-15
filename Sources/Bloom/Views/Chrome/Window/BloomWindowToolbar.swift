import SwiftUI
import BloomCore

/// The detail column's toolbar. NavigationSplitView owns the sidebar toggle so it stays over
/// the sidebar while expanded. Search and the inspector use standard toolbar buttons; only the
/// pull request band needs a title-bar accessory to follow the inspector's width.
struct BloomWindowToolbar: ToolbarContent {
    let app: AppModel
    let startFreshAskConversation: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            WindowTitleControl(app: app)
                .padding(.leading, Metrics.spacingWide)
        }
        // The editable window title is text, so it does not need a button's background.
        .sharedBackgroundVisibility(.hidden)

        if app.selection == .ask, app.ask.session != nil {
            ToolbarItem(placement: .navigation) {
                Button(action: startFreshAskConversation) {
                    Image(systemName: "square.and.pencil")
                }
                .help("Start a new Ask Bloom conversation")
                .accessibilityLabel("Start a new Ask Bloom conversation")
            }
        }

        ToolbarSpacer(.flexible, placement: .navigation)

        // First of the trailing group, so the inspector toggle keeps the window's edge the way
        // the sidebar toggle keeps the other one. Only on a workspace: Home and Ask Bloom have no
        // centre column to open a tab in, and a `+` that does nothing there is worse than none.
        // `selectedModel` rather than `selectedWorkspace`, because the menu acts on the model and
        // a model not prepared yet has nothing for it to act on.
        if let workspace = app.selectedModel, app.selectedWorkspace != nil {
            ToolbarItem(placement: .primaryAction) {
                NewTabMenu(model: workspace)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Search", systemImage: "magnifyingglass") {
                SearchPanelModel.shared.open(app: app)
            }
            .help("Search workspaces, transcripts and commands")
        }

        if app.selectedWorkspace != nil {
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
