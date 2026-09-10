import SwiftUI

/// The machine is a qualifier on the same project or prompt, so changing it never swaps the form.
struct CreationDestinationPicker: View {
    @Binding var isRemote: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    private var serverLabel: String { app.remoteServer.displayName }

    var body: some View {
        Menu {
            Picker("Create on", selection: $isRemote) {
                Label("This Mac", systemImage: "laptopcomputer").tag(false)
                if app.remoteServer.isConfigured {
                    Label(serverLabel, systemImage: "server.rack").tag(true)
                }
            }
            .pickerStyle(.inline)
            if app.remoteServer.savedServers.profiles.count > 1 {
                Menu("Other Servers") {
                    ForEach(app.remoteServer.savedServers.profiles) { profile in
                        if profile.id != app.remoteServer.connectionProfile?.id {
                            Button(profile.displayName) {
                                Task { await app.remoteServer.selectServer(profile); isRemote = true }
                            }
                        }
                    }
                }
                .disabled(app.remoteServer.isConnecting || app.remoteServer.isPerformingCommand)
            }
            Divider()
            Button("Add Server…") { openWindow(id: ServerSetupWindow.id) }
            if app.remoteServer.isConfigured {
                Button("Server Settings…") { openWindow(id: ServerWindow.id) }
            }
        } label: {
            Label(isRemote ? (serverLabel) : "This Mac",
                systemImage: isRemote ? "server.rack" : "laptopcomputer")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Create on")
    }
}
