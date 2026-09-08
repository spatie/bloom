import SwiftUI
import BloomCore
import UniformTypeIdentifiers

struct RemoteWorkspaceCreationView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var showsRepositoryPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.workspaceDestination == .remote {
                    Text(model.host.isEmpty ? "Configure the remote connection first." : "Runs on \(model.host)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.host.isEmpty {
                    Button("Configure Server…") { openWindow(id: ServerWindow.id) }
                }
                HStack {
                    TextField("Repository", text: $model.repositoryPath, prompt: Text("Git URL or path on the server"))
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
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isPerformingCommand || model.isConnecting)
                Spacer()
                if model.isPerformingCommand || model.isConnecting { ProgressView().controlSize(.small) }
                Button("Create Workspace") { Task {
                        await model.createWorkspace()
                        if !model.showsNewWorkspace, let id = model.selectedSessionID {
                            app.selection = .remote(id)
                            openWindow(id: BloomApp.mainWindowID)
                            dismiss()
                        }
                    } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isPerformingCommand || model.isConnecting || model.repositoryPath.isEmpty || model.workspaceName.isEmpty || model.agentModel.isEmpty)
            }
            .padding()
        }
        .frame(width: 620, height: 500)
        .onAppear { model.workspaceDestination = .remote; model.showsNewWorkspace = true }
        .interactiveDismissDisabled(model.isPerformingCommand || model.isConnecting)
        .fileImporter(isPresented: $showsRepositoryPicker, allowedContentTypes: [.folder]) { result in
            do { model.localRepositoryPath = try result.get().path } catch { model.error = error.localizedDescription }
        }
    }
}
