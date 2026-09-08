import SwiftUI
import BloomCore

/// A remote worktree uses the same conversation, terminal and browser surfaces as a local one.
struct RemoteWorkspaceContentView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Pane", selection: $model.activePane) {
                    Text("Chat").tag("chat")
                    Text("Terminal").tag("terminal")
                    Text("Preview").tag("preview")
                }
                .pickerStyle(.segmented).frame(width: 240)
                if let workspace = model.selectedWorkspace {
                    Picker("Conversation", selection: Binding(get: { model.selectedSessionID }, set: { id in
                        if let id { app.selection = .remote(id) }
                    })) {
                        ForEach(model.catalogue?.sessions.filter { $0.workspaceID == workspace.id } ?? []) { session in
                            Text(session.title.isEmpty ? "Chat" : session.title).tag(Optional(session.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 180)
                }
                Button("New Chat", systemImage: "plus") { Task {
                    if let id = await model.newChat() { app.selection = .remote(id); model.activePane = "chat" }
                } }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(!model.isConnected || model.isPerformingCommand)
                Spacer(minLength: 0)
                Button("Session Settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Hairline()
            if model.activePane == "terminal" {
                RemoteTerminalView(model: model)
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
                Text("Plan").tag(PermissionMode.plan)
                Text("Allow edits").tag(PermissionMode.acceptEdits)
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
