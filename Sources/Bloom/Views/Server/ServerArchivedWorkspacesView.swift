import SwiftUI
import BloomCore

struct ServerArchivedWorkspacesView: View {
    @Bindable var server: ServerWindowModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var restoring: WorkspaceID?
    /// The server's own confirmation for a permanent delete, held here because this sheet is what
    /// stays on screen while it is up. See `ServerRemovalRequest`.
    @State private var deleting: ServerRemovalRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text("Archived workspaces").font(Typo.title)
            Text(server.displayName).foregroundStyle(.secondary)
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
                    // The one irreversible thing here, so it opens the server's confirmation, which
                    // counts what goes, rather than doing anything itself.
                    Button("Delete Permanently\u{2026}", role: .destructive) {
                        restoring = workspace.id
                        Task {
                            deleting = await server.askToDelete(workspace)
                            restoring = nil
                        }
                    }.disabled(restoring != nil)
                }
            }
            if let error = server.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 600, height: 380)
        .task { await server.refreshCatalogue() }
        .confirmation($deleting) { $0.confirmation } onConfirm: { request in
            Task {
                if case .workspace(let id) = request.target { restoring = id }
                deleting = await server.confirm(request, app: app)
                restoring = nil
            }
        }
    }
}
