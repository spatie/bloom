import SwiftUI
import BloomCore

/// Browser and terminal workspaces have no transcript in which to show the setup event.
/// Keep the same row and disclosure available above their panes, including remote workspaces.
struct WorkspaceSetupStatusView<Model: WorkspacePaneModel>: View {
    @Bindable var model: Model
    @Environment(\.openWindow) private var openWindow
    @State private var isRetrying = false
    @State private var contentHeight: CGFloat = 36

    var body: some View {
        if model.remoteServer != nil || model.sessions.isEmpty, let event {
            ScrollView {
                WorkspaceEventRow(event: event, isFirstThing: false, model: model.localWorkspaceModel,
                                  onRunSetupAgain: retryAction, onRecoverDocker: dockerAction)
                    .padding(.top, Metrics.spacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 36), 220))
            Divider().overlay(Palette.border)
        }
    }

    private var event: WorkspaceEvent? {
        if let local = model.localWorkspaceModel {
            return local.timeline(isRunningSetup: model.isRunningSetup).first { $0.kind == .setup }
        }
        return WorkspaceEvent.setup(state: model.workspace.setupState, log: model.workspace.setupLog,
                                    durationMS: nil)
    }

    private var dockerAction: (@MainActor () -> Void)? {
        guard let server = model.remoteServer, let event, event.outcome == .failed,
              ServerDockerRecovery.isSetupFailure(log: event.log),
              let request = ServerDockerRecoveryRequest(server: server, workspaceID: model.workspace.id) else { return nil }
        return { openWindow(id: ServerDockerRecoveryWindow.id, value: request) }
    }

    private var retryAction: (@MainActor () -> Void)? {
        guard let server = model.remoteServer, let endpoint = server.endpoint, !isRetrying, !model.isRunningSetup,
              !server.isRunning(model.workspace), !server.isAwaitingPermission(model.workspace) else { return nil }
        return {
            let workspace = model.workspace
            isRetrying = true
            Task {
                guard server.endpoint == endpoint else { isRetrying = false; return }
                await server.updateWorkspace(workspace, action: .runSetup)
                isRetrying = false
            }
        }
    }
}
