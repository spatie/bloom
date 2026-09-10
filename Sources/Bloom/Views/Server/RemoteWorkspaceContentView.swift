import SwiftUI
import BloomCore
import BloomClient

/// Remote workspaces supply data to Bloom's standard tab and pane hierarchy.
struct RemoteWorkspaceContentView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @State private var workspace: RemoteWorkspaceFileListing?
    @State private var uiBridge: RemoteUIClientSession?

    var body: some View {
        Group {
            if let workspace, workspace.workspace.id == model.selectedWorkspace?.id {
                CenterColumnView(model: workspace)
            } else {
                LoadingView("Opening workspace")
            }
        }
        .task(id: (model.selectedWorkspace?.id.rawValue ?? "") + String(model.connectionGeneration)) {
            uiBridge?.stop()
            workspace = model.workspaceModel(app: app)
            guard let workspace, let service = model.uiBridgeService() else { return }
            let router = RemoteUIActionRouter(app: app, server: model, workspaceID: workspace.workspace.id)
            let session = RemoteUIClientSession(workspaceID: workspace.workspace.id, actions: RemoteUIActionRouter.actions) { action in
                await router.perform(action)
            }
            uiBridge = session
            session.start(using: service)
        }
        .onDisappear { uiBridge?.stop(); uiBridge = nil }
        .safeAreaInset(edge: .bottom) {
            if let error = uiBridge?.error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity)
            }
        }
    }
}
