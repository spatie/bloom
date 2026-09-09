import SwiftUI
import BloomCore

struct ServerArchivedWorkspacesView: View {
    @Bindable var server: ServerWindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var restoring: WorkspaceID?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text("Archived workspaces").font(Typo.title)
            Text(server.serverName).foregroundStyle(.secondary)
            List(server.catalogue?.archivedWorkspaces ?? []) { workspace in
                HStack {
                    VStack(alignment: .leading) {
                        Text(workspace.name)
                        Text(server.catalogue?.repositories.first { $0.id == workspace.repoID }?.name ?? "")
                            .font(Typo.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if restoring == workspace.id { ProgressView().controlSize(.small) }
                    Button("Restore") {
                        restoring = workspace.id
                        Task {
                            await server.restore(workspace, app: app)
                            restoring = nil
                            if server.catalogue?.workspaces.contains(where: { $0.id == workspace.id }) == true { dismiss() }
                        }
                    }.disabled(restoring != nil)
                }
            }
            if let error = server.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 520, height: 380)
        .task { await server.refreshCatalogue() }
    }
}
