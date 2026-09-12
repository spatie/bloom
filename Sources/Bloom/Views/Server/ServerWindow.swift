import SwiftUI
import BloomCore

/// Accounts, connection settings and storage share a utility window. Sessions use the main window.
struct ServerWindow: Scene {
    static let id = "bloom-server"
    let model: AppModel

    var body: some Scene {
        Window("Server Settings", id: Self.id) {
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
    @State private var storage: ServerStorageModel
    @State private var editorID = UUID()

    init(server: ServerWindowModel) {
        self.server = server
        _setup = State(initialValue: ServerSetupModel(server: server))
        _showsSetup = State(initialValue: false)
        _storage = State(initialValue: ServerStorageModel(server: server))
    }

    var body: some View {
        Group {
            if showsSetup {
                ServerSetupView(model: setup) { showsSetup = false }
            } else {
                ServerConnectionView(model: server, storage: storage) {
                    setup.cancel()
                    setup = ServerSetupModel(server: server, resumeExisting: server.isConnected)
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
    let storage: ServerStorageModel
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
    @State private var section: ServerSettingsSection? = .connection

    var body: some View {
        SettingsLayout {
            List(selection: $section) {
                Section("Server") {
                    ForEach(ServerSettingsSection.allCases, id: \.self) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
            }
        } detail: {
            VStack(spacing: 0) {
                serverPicker
                switch section ?? .connection {
                case .connection:
                    connectionForm
                    Divider()
                    connectionFooter
                case .accounts:
                    ServerAccountsContent(server: model, embedded: true) { section = .connection }
                        .id(model.connectionProfile?.id)
                case .storage:
                    ServerStorageView(model: storage) { section = .connection }
                }
            }
        }
        .navigationTitle((section ?? .connection).title)
        .disabled(model.isConnecting || model.isSigningIn)
        .onAppear(perform: loadConnection)
        .onChange(of: model.connectionProfile?.id) { loadConnection() }
    }

    private var serverPicker: some View {
        HStack {
            Label(model.displayName, systemImage: "server.rack")
                .font(Typo.labelEmphasis).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.savedServers.profiles.count > 1 {
                Menu("Change Server") {
                    ForEach(model.savedServers.profiles) { profile in
                        Button(profile.displayName) { Task { await model.selectServer(profile); loadConnection() } }
                    }
                }
                .disabled(storage.isCleaning)
            }
        }
        .padding(Metrics.gutter)
    }

    private var connectionForm: some View {
        Form {
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
            if let error = model.error ?? model.connectionRecovery.lastError {
                Text(ServerSetupDiagnostics.sanitise(error)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .settingsForm()
    }

    private var connectionFooter: some View {
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
        .padding(16)
    }

    private func loadConnection() {
        host = model.host; executable = model.executable; directory = model.remoteDirectory
        identityFile = model.identityFile; usesHTTPS = model.usesHTTPS; httpsAddress = model.httpsAddress
        label = model.customLabel
    }
}

private enum ServerSettingsSection: Hashable, CaseIterable {
    case connection, accounts, storage

    var title: String {
        switch self {
        case .connection: "Connection"
        case .accounts: "Accounts"
        case .storage: "Storage & Cleanup"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: "network"
        case .accounts: "person.crop.circle"
        case .storage: "externaldrive"
        }
    }
}
