import SwiftUI
import BloomCore

/// A remote worktree uses the same conversation, terminal and browser surfaces as a local one.
struct RemoteWorkspaceContentView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            RemoteWorkspaceTabsView(model: model)
            if model.activePane == "terminal" {
                RemoteTerminalView(model: model, name: model.selectedTerminal)
            } else if model.activePane == "review" {
                RemoteReviewPane(server: model)
            } else if model.activePane == "preview" {
                RemotePreviewView(model: model)
            } else {
                RemoteConversationView(model: model)
            }
        }
        .onChange(of: model.selectedWorkspace?.id) { _, _ in model.activePane = "chat" }
    }
}
