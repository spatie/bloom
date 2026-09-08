import SwiftUI
import BloomCore
import UniformTypeIdentifiers

/// A separate window is the initial remote surface. Local workspaces remain usable beside it.
struct ServerWindow: Scene {
    static let id = "bloom-server"

    var body: some Scene {
        Window("Bloom Server", id: Self.id) {
            ServerWindowView()
                .frame(minWidth: 850, minHeight: 600)
                .windowRole(.utility)
        }
        .defaultSize(width: 1_100, height: 760)
    }
}

struct ServerWindowView: View {
    @State private var model = ServerWindowModel()
    @State private var showsRepositoryPicker = false
    private let isRemoteApp = Bundle.main.bundleIdentifier == Store.remoteBundleIdentifier

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                HStack {
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.error = nil }
                }
                .padding()
                .background(.quaternary)
            }
            if model.isConnected {
                connected.inspector(isPresented: $model.showsReview) {
                    ServerReviewView(model: model.review).inspectorColumnWidth(min: 330, ideal: 480, max: 900)
                }
            } else { connectionForm }
        }
        .task(id: model.connectionGeneration) { await model.poll() }
        .task(id: model.connectionGeneration) { await model.pollReview() }
        .task {
            if isRemoteApp, !model.host.isEmpty, !model.executable.isEmpty, !model.directory.isEmpty {
                await model.connect()
            }
        }
        .onDisappear { Task { await model.disconnect() } }
        .sheet(isPresented: $model.showsNewWorkspace) { newWorkspace }
        .onChange(of: model.agent) { _, agent in
            model.agentModel = agent == .claudeCode ? AppDefaults.fallbackModel : ""
        }
        .confirmationDialog("Stop the local server?", isPresented: $model.showsStopServerConfirmation, titleVisibility: .visible) {
            Button("Stop Server", role: .destructive) { Task { await model.stopLocalServer() } }
        } message: {
            Text("All agents on this local server will stop. Their conversations remain available when you start it again.")
        }
    }

    private var connectionForm: some View {
        Form {
            Section {
                Picker("Machine", selection: $model.connectionMode) {
                    Text("Remote machine").tag(ServerWindowModel.ConnectionMode.remote)
                    Text("This Mac").tag(ServerWindowModel.ConnectionMode.local)
                    Text("Existing local server").tag(ServerWindowModel.ConnectionMode.existingLocal)
                }
                if model.connectionMode == .remote {
                    TextField("SSH host", text: $model.host, prompt: Text("user@machine or SSH alias"))
                    TextField("Server executable", text: $model.executable, prompt: Text("/absolute/path/to/bloom-server"))
                }
                if model.connectionMode != .local {
                    TextField("Server data directory", text: $model.directory, prompt: Text("/absolute/path/to/server-data"))
                }
            } header: {
                Text("Connect to a Bloom server")
            } footer: {
                switch model.connectionMode {
                case .remote:
                    Text("Start the server on that machine first. Verify SSH access in Terminal and load your key into the SSH agent.")
                case .local:
                    Text("Bloom starts a background server on this Mac. It keeps agents running after Bloom closes and starts at login.")
                case .existingLocal:
                    Text("Connect to a standalone server already running on this Mac.")
                }
            }
            .disabled(model.isConnecting || model.isPerformingCommand)
            HStack {
                if model.isConnecting { ProgressView().controlSize(.small) }
                if model.needsBackgroundApproval {
                    Button("Open Login Items") { model.localService.openLoginItems() }
                }
                Button(model.connectionMode == .local ? "Start Local Server" : "Connect") { Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isConnecting || model.isPerformingCommand || (model.connectionMode != .local && model.directory.isEmpty))
                if model.connectionMode == .local, model.localService.isRegistered {
                    Button("Stop Local Server", role: .destructive) { model.showsStopServerConfirmation = true }
                        .disabled(model.isConnecting || model.isPerformingCommand)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connected: some View {
        NavigationSplitView {
            List(selection: $model.selectedSessionID) {
                ForEach(model.catalogue?.workspaces ?? []) { workspace in
                    Section(workspace.name) {
                        ForEach((model.catalogue?.sessions ?? []).filter { $0.workspaceID == workspace.id }) { session in
                            VStack(alignment: .leading) {
                                Text(session.title)
                                Text(session.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(session.id)
                        }
                    }
                }
            }
            .navigationTitle(isRemoteApp ? "Bloom Remote" : model.serverName)
            .navigationSubtitle("\(model.destinationLabel): \(model.serverName)")
            .toolbar {
                Picker("Machine", selection: Binding(
                    get: { model.connectionMode }, set: { destination in Task { await model.switchMachine(destination) } }
                )) {
                    Text("Remote server").tag(ServerWindowModel.ConnectionMode.remote)
                    Text("This Mac").tag(ServerWindowModel.ConnectionMode.local)
                    if model.connectionMode == .existingLocal {
                        Text("Existing local server").tag(ServerWindowModel.ConnectionMode.existingLocal)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.isConnecting || model.isPerformingCommand)
                Button("New Workspace", systemImage: "plus") { model.prepareNewWorkspace() }
                    .disabled(model.isConnecting || model.isPerformingCommand)
                Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnect() } }
                Button("Show Changes", systemImage: "sidebar.right") { model.showsReview.toggle() }
                if model.connectionMode == .local {
                    Button("Stop Local Server", systemImage: "stop.circle") { model.showsStopServerConfirmation = true }
                        .disabled(model.isPerformingCommand)
                }
            }
        } detail: {
            if model.selectedSessionID != nil { conversation } else {
                ContentUnavailableView {
                    Label(model.destinationLabel + " workspaces", systemImage: model.connectionMode == .remote ? "server.rack" : "desktopcomputer")
                } description: {
                    Text("Select a conversation or create a workspace on \(model.serverName).")
                } actions: {
                    Button("New Workspace") { model.prepareNewWorkspace() }
                }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { ServerMessageView(message: $0) }
                    if !model.streamingText.isEmpty { Text(model.streamingText).textSelection(.enabled) }
                    ForEach(model.questions) { ask in
                        if ask.isQuestion {
                            AgentQuestionCard(ask: ask, decision: nil) { decision in
                                if case .answer(let input) = decision {
                                    Task { await model.answer(ask, decision: .question(input: input)) }
                                } else {
                                    Task { await model.answer(ask, decision: .deny) }
                                }
                            }
                            .disabled(model.isPerformingCommand)
                        } else {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(ask.summary.isEmpty ? ask.toolName : ask.summary).fontWeight(.semibold)
                                    Text(ask.input.prettyPrinted).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    HStack {
                                        Button("Allow Once") { Task { await model.answer(ask, decision: .allowOnce) } }
                                        Button("Deny") { Task { await model.answer(ask, decision: .deny) } }
                                    }
                                    .disabled(model.isPerformingCommand)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .defaultScrollAnchor(.bottom)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Running on \(model.serverName)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.draft).frame(height: 90).accessibilityLabel("Prompt")
                HStack {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(model.questions.isEmpty ? "Working" : "Waiting for your answer").font(.caption)
                    }
                    Spacer()
                    Button("Stop") { Task { await model.stop() } }
                        .disabled(!model.isBusy || model.isPerformingCommand)
                    Button("Send") { Task { await model.send() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.isBusy || model.isPerformingCommand || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
    }

    private var newWorkspace: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Create on", selection: $model.workspaceDestination) {
                    Text("Remote server").tag(ServerWindowModel.ConnectionMode.remote)
                    Text("This Mac").tag(ServerWindowModel.ConnectionMode.local)
                    if model.connectionMode == .existingLocal {
                        Text("Existing local server").tag(ServerWindowModel.ConnectionMode.existingLocal)
                    }
                }
                .pickerStyle(.segmented)
                if model.workspaceDestination == .remote {
                    Text(model.host.isEmpty ? "Configure the remote connection first." : "Runs on \(model.host)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField(model.workspaceDestination == .remote ? "Repository on server" : "Repository on this Mac", text: $model.repositoryPath, prompt: Text("/absolute/path/to/repository"))
                    if model.workspaceDestination != .remote {
                        Button("Choose…") { showsRepositoryPicker = true }
                    }
                }
                TextField("Workspace name", text: $model.workspaceName)
                Picker("Agent", selection: $model.agent) {
                    Text("Claude Code").tag(AgentKind.claudeCode)
                    Text("Codex").tag(AgentKind.codex)
                }
                TextField("Model", text: $model.agentModel)
                TextField("Effort", text: $model.effort)
                Picker("Permissions", selection: $model.permissionMode) {
                    Text(PermissionMode.plan.label(on: model.agent)).tag(PermissionMode.plan)
                    Text(PermissionMode.acceptEdits.label(on: model.agent)).tag(PermissionMode.acceptEdits)
                }
                Text(model.workspaceDestination == .remote
                     ? "Creates the worktree and runs setup and agents on the remote server."
                     : "Creates the worktree and runs setup and agents on this Mac. The local server keeps working when you close the app.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            .disabled(model.isPerformingCommand || model.isConnecting)
            HStack {
                Button("Cancel") { model.showsNewWorkspace = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isPerformingCommand || model.isConnecting)
                Spacer()
                if model.isPerformingCommand || model.isConnecting { ProgressView().controlSize(.small) }
                Button("Create Workspace") { Task { await model.createWorkspace() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isPerformingCommand || model.isConnecting || model.repositoryPath.isEmpty || model.workspaceName.isEmpty || model.agentModel.isEmpty)
            }
            .padding()
        }
        .frame(width: 620, height: 560)
        .interactiveDismissDisabled(model.isPerformingCommand || model.isConnecting)
        .fileImporter(isPresented: $showsRepositoryPicker, allowedContentTypes: [.folder]) { result in
            do { model.localRepositoryPath = try result.get().path } catch { model.error = error.localizedDescription }
        }
    }
}
