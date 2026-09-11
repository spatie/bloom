import SwiftUI
import BloomCore
import BloomClient

/// Remote workspaces supply data to Bloom's standard tab and pane hierarchy.
struct RemoteWorkspaceContentView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var workspace: RemoteWorkspaceFileListing?
    @State private var showsConnectionFailure = false
    @State private var uiBridge: RemoteUIClientSession?

    private var availability: RemoteWorkspaceAvailability {
        RemoteWorkspaceAvailability.resolve(
            hasWorkspace: model.selectedWorkspace != nil,
            hasModel: workspace != nil && workspace?.workspace.id == model.selectedWorkspace?.id,
            isConfigured: model.isConfigured, isConnected: model.isConnected,
            isConnecting: model.isConnecting, hasCatalogue: model.catalogue != nil,
            workspaceCount: model.catalogue?.workspaces.count ?? 0
        )
    }

    var body: some View {
        Group {
            if let workspace, workspace.workspace.id == model.selectedWorkspace?.id {
                CenterColumnView(model: workspace)
            } else {
                unavailableContent
            }
        }
        .task(id: (model.selectedWorkspace?.id.rawValue ?? "") + String(model.connectionGeneration)) {
            uiBridge?.stop()
            uiBridge = nil
            workspace = model.workspaceModel(app: app)
            guard let workspace, let service = model.uiBridgeService() else { return }
            let router = RemoteUIActionRouter(app: app, server: model, workspaceID: workspace.workspace.id)
            let session = RemoteUIClientSession(workspaceID: workspace.workspace.id, actions: RemoteUIActionRouter.actions) { action in
                await router.perform(action)
            }
            uiBridge = session
            session.start(using: service)
        }
        .popover(isPresented: $showsConnectionFailure) { ServerConnectionFailureView(server: model) }
        .onDisappear { uiBridge?.stop(); uiBridge = nil }
        .safeAreaInset(edge: .top, spacing: 0) { connectionNotice }
        .safeAreaInset(edge: .bottom) {
            if model.connectionRecovery.phase == .connected, let error = uiBridge?.error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var connectionNotice: some View {
        let recovery = model.connectionRecovery
        if model.isConfigured, recovery.phase != .connected || model.selectedPendingSend != nil {
            VStack(alignment: .leading, spacing: 8) {
                if recovery.phase != .connected {
                    HStack(alignment: .top, spacing: 10) {
                        if recovery.phase == .connecting || recovery.phase == .reconnecting {
                            ProgressView().controlSize(.small)
                        } else { Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recovery.title).font(Typo.captionEmphasis)
                            Text(recovery.detail).font(Typo.caption).foregroundStyle(.secondary)
                            if recovery.lastError != nil {
                                Button("Connection details…") { showsConnectionFailure = true }.font(Typo.caption)
                            }
                        }
                        Spacer(minLength: 8)
                        if recovery.canRetry {
                            Button("Retry Now") { Task { await model.connect() } }
                                .disabled(model.isConnecting || model.isRemovingServer || model.isDisconnecting)
                        }
                    }
                }
                if model.selectedPendingSend != nil {
                    HStack(alignment: .top, spacing: 10) {
                        let sending = model.sendingSessionID == model.selectedSessionID
                        Image(systemName: sending ? "paperplane" : "exclamationmark.bubble").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sending ? "Sending message" : "Message awaiting confirmation").font(Typo.captionEmphasis)
                            Text(sending ? "Waiting for the server to confirm receipt."
                                 : "It may already be on the server. Retry checks the same message without creating a duplicate.")
                                .font(Typo.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Retry Message") { Task { await model.retryPendingSend() } }
                            .disabled(sending || !model.isConnected || model.isConnecting || model.isPerformingCommand)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var unavailableContent: some View {
        switch availability {
        case .ready, .opening:
            LoadingView("Opening workspace")
        case .connecting:
            VStack(spacing: 16) {
                LoadingView("Connecting to \(model.displayName)")
                Button("Go Home") { app.clearRemoteSelection() }
            }
        case .disconnected:
            ContentUnavailableView {
                Label("Server disconnected", systemImage: "network.slash")
            } description: {
                Text(model.error ?? "Connect to \(model.displayName) to open this workspace.").textSelection(.enabled)
            } actions: {
                Button("Connect") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
                Button("Server Settings…") { openWindow(id: ServerWindow.id) }
                Button("Go Home") { app.clearRemoteSelection() }
            }
        case .unconfigured:
            ContentUnavailableView {
                Label("No server connected", systemImage: "server.rack")
            } description: {
                Text("Connect a server to open its projects and workspaces.")
            } actions: {
                Button("Connect a Server…") { openWindow(id: ServerWindow.id) }.buttonStyle(.borderedProminent)
                Button("Go Home") { app.clearRemoteSelection() }
            }
        case .empty, .missing:
            ContentUnavailableView {
                Label(availability == .empty ? "No workspaces on this server" : "Workspace unavailable", systemImage: "folder")
            } description: {
                Text(availability == .empty
                     ? "Start a project on \(model.displayName) to create your first workspace."
                     : "This workspace is no longer in the server's workspace list. Choose another workspace or start a project.")
            } actions: {
                Button("Start a Project…") {
                    StartProjectOpening.shared.isRemote = true
                    openWindow(id: StartProjectWindow.id)
                }.buttonStyle(.borderedProminent)
                Button("Go Home") { app.clearRemoteSelection() }
            }
        }
    }
}
