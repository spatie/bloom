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
