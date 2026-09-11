import SwiftUI
import BloomCore

/// Servers are flat group headings, at the same depth as This Mac.
struct SidebarServerHeader: View {
    @Bindable var server: ServerWindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var hovered = false
    @State private var showsConnectionFailure = false
    @State private var isRenaming = false
    @State private var label = ""
    @State private var showsRemoval = false
    @State private var removalProfile: ServerConnectionProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            connectionStatus
        }
        .popover(isPresented: $showsConnectionFailure) { ServerConnectionFailureView(server: server) }
        .onChange(of: server.isConnected) { _, connected in
            if connected { showsConnectionFailure = false }
        }
    }

    private var header: some View {
        HStack(spacing: Metrics.spacing) {
            Button { openWindow(id: ServerWindow.id) } label: {
                Image(systemName: hovered ? "gearshape" : "server.rack")
                    .frame(width: 16, height: 18)
            }
            .buttonStyle(.plain)
            .help("Server settings")
            Text(server.displayName).lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            if server.isConnecting { ProgressView().controlSize(.mini) }
            Spacer(minLength: 0)
            Menu { actions } label: { Image(systemName: "ellipsis").frame(width: 22, height: 18) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Server actions")
        }
        .font(Typo.captionEmphasis)
        .foregroundStyle(Palette.textSecondary)
        .contentShape(Rectangle())
        .onHoverChange { hovered = $0 }
        .contextMenu { actions }
        .alert("Rename Server", isPresented: $isRenaming) {
            TextField("Server label", text: $label)
            Button("Cancel", role: .cancel) {}
            Button("Save") { server.renameServer(label) }
        } message: { Text("This label is used in Bloom. Leave it empty to use the hostname.") }
        .alert("Remove Server?", isPresented: $showsRemoval, presenting: removalProfile) { profile in
            Button("Cancel", role: .cancel) {}
            Button("Remove Server", role: .destructive) {
                Task { await server.removeServer(profile) { app.clearRemoteSelection() } }
            }
            .disabled(!server.canRemoveServer || server.connectionProfile?.id != profile.id)
        } message: { profile in
            Text("\(profile.displayName) will be removed from Bloom on this Mac. Projects and processes on the server will keep running. Local drafts and SSH keys will be kept.")
        }
    }

    private var hasConnectionFailure: Bool {
        server.connectionRecovery.phase != .disconnected && server.connectionRecovery.lastError != nil
    }

    @ViewBuilder private var connectionStatus: some View {
        if !server.isConnected || server.isConnecting {
            HStack(spacing: 6) {
                if hasConnectionFailure {
                    Button { showsConnectionFailure = true } label: {
                        Label(server.isConnecting ? "Retrying connection…" : "Could not connect",
                              systemImage: "exclamationmark.triangle")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.warning)
                    .help("Show the connection error and retry options")
                } else {
                    Text(server.isConnecting ? "Connecting…" : "Disconnected")
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
                if !server.isConnecting {
                    Button(hasConnectionFailure ? "Retry" : "Connect") {
                        Task { await server.connect() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(server.isRemovingServer || server.isDisconnecting)
                }
            }
            .font(Typo.caption)
            .padding(.leading, 24)
        }
    }

    @ViewBuilder private var actions: some View {
        if server.isConnected {
            Button("Disconnect") { Task { await server.disconnect() } }
        } else {
            Button("Connect") { Task { await server.connect() } }.disabled(server.isConnecting)
        }
        if hasConnectionFailure {
            Button("Connection Details…") { showsConnectionFailure = true }
        }
        Divider()
        Button("Start a Project…") {
            StartProjectOpening.shared.isRemote = true
            openWindow(id: StartProjectWindow.id)
        }
        .disabled(!server.isConnected || server.isConnecting)
        Button("Rename Server…") { label = server.displayName; isRenaming = true }
        Button("Server Settings…") { openWindow(id: ServerWindow.id) }
        if server.savedServers.profiles.count > 1 {
            Menu("Switch Server") {
                ForEach(server.savedServers.profiles) { profile in
                    Button(profile.displayName) { Task { await server.selectServer(profile) } }
                        .disabled(profile.id == server.connectionProfile?.id)
                }
            }
            .disabled(server.isConnecting || server.isPerformingCommand)
        }
        Button("Add Server…") { openWindow(id: ServerSetupWindow.id) }
        Button("Archived Workspaces…") { server.showsArchivedWorkspaces = true }
            .disabled(!server.isConnected || server.isConnecting)
        Divider()
        Button("Remove Server…", role: .destructive) {
            removalProfile = server.connectionProfile
            showsRemoval = removalProfile != nil
        }
        .disabled(!server.canRemoveServer)
    }
}
