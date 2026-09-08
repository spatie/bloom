import SwiftUI
import BloomCore

/// Connection setup belongs to a small utility window. Sessions use Bloom's main window.
struct ServerWindow: Scene {
    static let id = "bloom-server"
    let model: AppModel

    var body: some Scene {
        Window("Server Connection", id: Self.id) {
            ServerConnectionView(model: model.remoteServer)
                .environment(model)
                .windowRole(.utility)
        }
        .defaultSize(width: 660, height: 340)
    }
}

private struct ServerConnectionView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var host = ""
    @State private var executable = ""
    @State private var directory = ""

    var body: some View {
        Form {
            Section("Remote machine") {
                TextField("SSH host", text: $host, prompt: Text("user@machine or SSH alias"))
                TextField("Server executable", text: $executable, prompt: Text("/absolute/path/to/bloom-server"))
                TextField("Server data directory", text: $directory)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if model.isConnecting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Connect") {
                    Task {
                        model.host = host; model.executable = executable; model.remoteDirectory = directory
                        model.connectionMode = .remote
                        await model.connect()
                        if model.isConnected {
                            if let session = model.catalogue?.sessions.first { app.selection = .remote(session.id) }
                            dismissWindow(id: ServerWindow.id)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || executable.isEmpty || directory.isEmpty)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isConnecting)
        .onAppear { host = model.host; executable = model.executable; directory = model.remoteDirectory }
    }
}
