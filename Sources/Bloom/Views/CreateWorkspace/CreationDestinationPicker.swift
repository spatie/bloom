import SwiftUI

/// The machine is a qualifier on the same project or prompt, so changing it never swaps the form.
struct CreationDestinationPicker: View {
    @Binding var isRemote: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    private var serverLabel: String { app.remoteServer.displayName }

    var body: some View {
        // Absent rather than reduced to "This Mac" with the switch off, because a menu with one
        // choice in it is a question nobody needs asked. The windows that hold it put `isRemote`
        // back to false themselves, since a view that is not drawn runs no `onChange`.
        if RemoteServerAvailability.shared.isEnabled {
            menu
        }
    }

    private var menu: some View {
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
            // The same label, style and chevron as the project menu beside it. This was a plain
            // `Label` in a `.borderlessButton` menu, which the system draws in its own control font
            // with its own small chevron hard against the text, so the two menus in one row read
            // as two kinds of control: one bolder and larger, one quiet. They are one kind.
            ComposerControlLabel(
                systemImage: isRemote ? "server.rack" : "laptopcomputer",
                text: isRemote ? serverLabel : "This Mac",
                tint: Palette.textPrimary,
                showsMenuIndicator: true
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose where the workspace is created")
        .accessibilityLabel("Create on")
        .accessibilityValue(isRemote ? serverLabel : "This Mac")
    }
}
