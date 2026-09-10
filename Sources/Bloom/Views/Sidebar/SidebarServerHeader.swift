import SwiftUI

/// Servers are flat group headings, at the same depth as This Mac.
struct SidebarServerHeader: View {
    @Bindable var server: ServerWindowModel
    @Environment(\.openWindow) private var openWindow
    @State private var hovered = false
    @State private var isRenaming = false
    @State private var label = ""

    var body: some View {
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
    }

    @ViewBuilder private var actions: some View {
        if server.isConnected {
            Button("Disconnect") { Task { await server.disconnect() } }
        } else {
            Button("Connect") { Task { await server.connect() } }.disabled(server.isConnecting)
        }
        Divider()
        Button("Start a Project…") {
            StartProjectOpening.shared.isRemote = true
            openWindow(id: StartProjectWindow.id)
        }
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
    }
}
