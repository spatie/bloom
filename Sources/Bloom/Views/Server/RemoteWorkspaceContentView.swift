import SwiftUI
import BloomCore

/// Remote workspaces supply data to Bloom's standard tab and pane hierarchy.
struct RemoteWorkspaceContentView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @State private var workspace: RemoteWorkspaceFileListing?

    var body: some View {
        Group {
            if let workspace, workspace.workspace.id == model.selectedWorkspace?.id {
                CenterColumnView(model: workspace)
            } else {
                LoadingView("Opening workspace")
            }
        }
        .task(id: model.selectedWorkspace?.id) { workspace = model.workspaceModel(app: app) }
    }
}
