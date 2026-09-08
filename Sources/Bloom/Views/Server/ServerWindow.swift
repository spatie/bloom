import SwiftUI
import BloomCore

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

private struct ServerWindowView: View {
    @State private var model = ServerWindowModel()

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
        .onDisappear { Task { await model.disconnect() } }
        .sheet(isPresented: $model.showsNewWorkspace) { newWorkspace }
        .onChange(of: model.agent) { _, agent in
            model.agentModel = agent == .claudeCode ? AppDefaults.fallbackModel : ""
        }
    }

    private var connectionForm: some View {
        Form {
            Section {
                Picker("Machine", selection: $model.isRemote) {
                    Text("Remote machine").tag(true)
                    Text("This Mac").tag(false)
                }
                if model.isRemote {
                    TextField("SSH host", text: $model.host, prompt: Text("user@machine or SSH alias"))
                    TextField("Server executable", text: $model.executable, prompt: Text("/absolute/path/to/bloom-server"))
                }
                TextField("Server data directory", text: $model.directory, prompt: Text("/absolute/path/to/server-data"))
            } header: {
                Text("Connect to a Bloom server")
            } footer: {
                Text(model.isRemote
                     ? "Start the server on that machine first. Verify SSH access in Terminal and load your key into the SSH agent."
                     : "Connect to a standalone server already running on this Mac.")
            }
            HStack {
                if model.isConnecting { ProgressView().controlSize(.small) }
                Button("Connect") { Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isConnecting || model.directory.isEmpty)
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
            .navigationTitle(model.serverName)
            .toolbar {
                Button("New Workspace", systemImage: "plus") { model.showsNewWorkspace = true }
                    .disabled(model.isPerformingCommand)
                Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnect() } }
                Button("Show Changes", systemImage: "sidebar.right") { model.showsReview.toggle() }
            }
        } detail: {
            if model.selectedSessionID != nil { conversation } else {
                ContentUnavailableView {
                    Label("Server workspaces", systemImage: "server.rack")
                } description: {
                    Text("Select a conversation or create a workspace on \(model.serverName).")
                } actions: {
                    Button("New Workspace") { model.showsNewWorkspace = true }
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
                TextField("Repository on server", text: $model.repositoryPath, prompt: Text("/absolute/path/to/repository"))
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
                Text("Creates a git worktree and runs the repository's configured setup script on the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { model.showsNewWorkspace = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.isPerformingCommand { ProgressView().controlSize(.small) }
                Button("Create Workspace") { Task { await model.createWorkspace() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isPerformingCommand || model.repositoryPath.isEmpty || model.workspaceName.isEmpty || model.agentModel.isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 430)
        .interactiveDismissDisabled(model.isPerformingCommand)
    }
}
