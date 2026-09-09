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
        .windowResizability(.contentSize)
    }
}

private struct ServerConnectionView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var host = ""
    @State private var executable = ""
    @State private var identityFile = ""
    @State private var directory = ""
    @State private var usesHTTPS = false
    @State private var httpsAddress = ""

    var body: some View {
        Form {
            TextField("Server label", text: Binding(get: { model.customLabel }, set: { model.renameServer($0) }), prompt: Text("Use server hostname"))
            Picker("Connection", selection: $usesHTTPS) {
                Text("HTTPS").tag(true)
                Text("SSH").tag(false)
            }
            .pickerStyle(.segmented)
            if usesHTTPS {
                Section("Server") {
                    TextField("Server address", text: $httpsAddress, prompt: Text("https://bloom.example.com"))
                    Text("Sign in with the account allowed to access this server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { Section("Remote machine") {
                TextField("SSH host", text: $host, prompt: Text("user@machine or SSH alias"))
                TextField("Server executable", text: $executable, prompt: Text("/absolute/path/to/bloom-server"))
                TextField("Server data directory", text: $directory)
                TextField("SSH key (optional)", text: $identityFile, prompt: Text("Leave empty to use your SSH agent"))
            } }
            if model.isConnected { ServerDiagnosticsView(model: model) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if model.isConnecting || model.isSigningIn { ProgressView().controlSize(.small) }
                if usesHTTPS {
                    Button("Sign Out") { Task { await model.signOutHTTPS() } }
                }
                Spacer()
                Button(usesHTTPS ? "Sign In and Connect" : "Connect") {
                    Task {
                        model.host = host; model.executable = executable; model.remoteDirectory = directory; model.identityFile = identityFile
                        model.connectionMode = .remote
                        model.usesHTTPS = usesHTTPS
                        model.httpsAddress = httpsAddress
                        if usesHTTPS { await model.signInHTTPS() } else { await model.connect() }
                        if model.isConnected {
                            if let session = model.catalogue?.sessions.first { app.selectRemoteSession(session.id) }
                            dismissWindow(id: ServerWindow.id)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(usesHTTPS ? httpsAddress.isEmpty : (host.isEmpty || executable.isEmpty || directory.isEmpty))
            }
        }
        .formStyle(.grouped)
        .frame(width: 660, height: (usesHTTPS ? 300 : 390) + (model.isConnected ? 160 : 0))
        .disabled(model.isConnecting || model.isSigningIn)
        .onAppear { model.isEditingConnection = true; host = model.host; executable = model.executable; directory = model.remoteDirectory; identityFile = model.identityFile; usesHTTPS = model.usesHTTPS; httpsAddress = model.httpsAddress }
        .onDisappear { model.isEditingConnection = false }
    }
}
