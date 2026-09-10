import SwiftUI
import BloomCore

/// Connection setup belongs to a small utility window. Sessions use Bloom's main window.
struct ServerWindow: Scene {
    static let id = "bloom-server"
    let model: AppModel

    var body: some Scene {
        Window("Server Connection", id: Self.id) {
            ServerConnectionContent(server: model.remoteServer)
                .environment(model)
                .windowRole(.utility)
        }
        .windowResizability(.contentSize)
    }
}

private struct ServerConnectionContent: View {
    let server: ServerWindowModel
    @State private var setup: ServerSetupModel
    @State private var showsSetup: Bool
    @State private var editorID = UUID()

    init(server: ServerWindowModel) {
        self.server = server
        _setup = State(initialValue: ServerSetupModel(server: server))
        _showsSetup = State(initialValue: !server.isConfigured)
    }

    var body: some View {
        Group {
            if showsSetup {
                ServerSetupView(model: setup) { showsSetup = false }
            } else {
                ServerConnectionView(model: server) {
                    setup.cancel()
                    setup = ServerSetupModel(server: server)
                    showsSetup = true
                }
            }
        }
        .onAppear { server.setConnectionEditing(true, id: editorID) }
        .onDisappear { server.setConnectionEditing(false, id: editorID) }
    }
}

private struct ServerConnectionView: View {
    @Bindable var model: ServerWindowModel
    let showSetup: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var host = ""
    @State private var executable = ""
    @State private var identityFile = ""
    @State private var directory = ""
    @State private var usesHTTPS = false
    @State private var httpsAddress = ""
    @State private var label = ""

    var body: some View {
        Form {
            if !model.savedServers.profiles.isEmpty {
                LabeledContent("Saved servers") {
                    Menu(model.displayName) {
                        ForEach(model.savedServers.profiles) { profile in
                            Button(profile.displayName) { Task { await model.selectServer(profile); loadConnection() } }
                        }
                    }
                }
            }
            if let failure = model.savedServers.failure { Text(failure).foregroundStyle(Palette.warning) }
            TextField("Server label", text: $label, prompt: Text("Use server hostname"))
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
                Button("Guided Setup…", action: showSetup)
                Button("Add Server…") { openWindow(id: ServerSetupWindow.id) }
                if model.isConnecting || model.isSigningIn { ProgressView().controlSize(.small) }
                if usesHTTPS, model.usesHTTPS, httpsAddress == model.httpsAddress {
                    Button("Sign Out") { Task { await model.signOutHTTPS() } }
                }
                Spacer()
                Button(usesHTTPS ? "Sign In and Connect" : "Connect") {
                    Task {
                        guard let candidate = ServerConnectionProfile(values: [
                            "usesHTTPS": usesHTTPS ? "true" : "false", "httpsAddress": httpsAddress,
                            "host": host, "executable": executable, "directory": directory,
                            "identityFile": identityFile, "knownHostsFile": model.knownHostsFile,
                        ], label: label) else { return }
                        if await model.connect(to: candidate) {
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
        .onAppear(perform: loadConnection)
        .onChange(of: model.connectionProfile?.id) { loadConnection() }
    }

    private func loadConnection() {
        host = model.host; executable = model.executable; directory = model.remoteDirectory
        identityFile = model.identityFile; usesHTTPS = model.usesHTTPS; httpsAddress = model.httpsAddress
        label = model.customLabel
    }
}
