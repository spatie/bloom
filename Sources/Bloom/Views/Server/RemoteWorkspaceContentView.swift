import SwiftUI
import BloomCore

/// A remote worktree uses the same conversation, terminal and browser surfaces as a local one.
struct RemoteWorkspaceContentView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            RemoteWorkspaceTabsView(model: model, showsSettings: $showsSettings)
            if model.activePane == "terminal" {
                RemoteTerminalView(model: model, name: model.selectedTerminal)
            } else if model.activePane == "preview" {
                RemotePreviewView(model: model)
            } else {
                RemoteConversationView(model: model)
            }
        }
        .sheet(isPresented: $showsSettings) { RemoteSessionSettingsView(model: model) }
        .onChange(of: model.selectedWorkspace?.id) { _, _ in model.activePane = "chat" }
    }
}

private struct RemoteSessionSettingsView: View {
    var model: ServerWindowModel
    @Environment(\.dismiss) private var dismiss
    @State private var modelName = ""
    @State private var effort = "low"
    @State private var permissionMode = PermissionMode.plan
    var body: some View {
        Form {
            TextField("Model", text: $modelName)
            Picker("Effort", selection: $effort) {
                ForEach(["low", "medium", "high", "xhigh"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            Picker("Permissions", selection: $permissionMode) {
                ForEach(ComposerControls(agentKind: model.selectedSession?.agentKind ?? .codex).availablePermissionModes, id: \.self) { mode in
                    Text(mode.label(on: model.selectedSession?.agentKind ?? .codex)).tag(mode)
                }
            }
            if model.isBusy { Text("Stop the current turn to change these settings.").font(.caption).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { Task {
                    await model.configure(model: modelName, effort: effort, permissionMode: permissionMode)
                    if model.error == nil { dismiss() }
                } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || model.isPerformingCommand || modelName.isEmpty || !model.isConnected)
            }
        }
        .padding(24).frame(width: 420)
        .onAppear {
            if let session = model.selectedSession {
                modelName = session.model; effort = session.effort; permissionMode = session.permissionMode
            }
        }
    }
}
