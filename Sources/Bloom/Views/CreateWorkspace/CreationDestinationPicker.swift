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
            Divider()
            Button("Configure Server…") { openWindow(id: ServerWindow.id) }
        } label: {
            Label(isRemote ? (serverLabel) : "This Mac",
                systemImage: isRemote ? "server.rack" : "laptopcomputer")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Create on")
    }
}
