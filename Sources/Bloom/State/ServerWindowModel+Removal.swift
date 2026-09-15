import Foundation
import BloomCore

/// A permanent removal on a server, waiting for the reader's answer.
///
/// The endpoint is captured with the preview for the reason `archiveConfirmations` captures it:
/// a confirmation read about one server must never be sent to the next one somebody connected to.
struct ServerRemovalRequest: Identifiable, Equatable {
    enum Target: Equatable {
        case workspace(WorkspaceID)
        case project(RepoID)
    }

    var preview: ServerRemovalPreview
    var target: Target
    var endpoint: ServerEndpoint

    var id: UUID { preview.id }

    /// The server's words in the app's own dialog. Nothing here is worded on the Mac.
    var confirmation: Confirmation {
        Confirmation(title: preview.title, message: preview.message, confirmLabel: preview.confirmLabel,
                     cancelLabel: preview.cancelLabel, tone: .destructive)
    }
}

/// Deleting an archived workspace and removing a project, both decided on the server.
extension ServerWindowModel {
    func askToDelete(_ workspace: Workspace) async -> ServerRemovalRequest? {
        await ask(.workspace(workspaceID: workspace.id, action: .deletePreview), target: .workspace(workspace.id))
    }

    func askToRemove(_ repo: Repo) async -> ServerRemovalRequest? {
        await ask(.project(repoID: repo.id, action: .removalPreview), target: .project(repo.id))
    }

    private func ask(_ operation: ServerOperation, target: ServerRemovalRequest.Target) async -> ServerRemovalRequest? {
        guard let endpoint, case .removalPreview(let preview) = await perform(operation), self.endpoint == endpoint else { return nil }
        return ServerRemovalRequest(preview: preview, target: target, endpoint: endpoint)
    }

    /// Sends the confirmation back, and returns a fresh request when the server found that what
    /// it would remove has changed since the reader was shown it.
    func confirm(_ request: ServerRemovalRequest, app: AppModel) async -> ServerRemovalRequest? {
        guard endpoint == request.endpoint else {
            error = "The server connection changed. Choose the action again."
            return nil
        }
        let operation: ServerOperation = switch request.target {
        case .workspace(let id): .workspace(workspaceID: id, action: .delete(confirmation: request.preview.id))
        case .project(let id): .project(repoID: id, action: .remove(confirmation: request.preview.id))
        }
        let result = await perform(operation)
        guard endpoint == request.endpoint else { return nil }
        switch result {
        case .removalPreview(let fresh):
            return ServerRemovalRequest(preview: fresh, target: request.target, endpoint: request.endpoint)
        case .accepted, .text:
            if case .text(let note) = result { error = note }
            let gone: [WorkspaceID] = switch request.target {
            case .workspace(let id): [id]
            case .project(let id):
                ((catalogue?.workspaces ?? []) + (catalogue?.archivedWorkspaces ?? [])).filter { $0.repoID == id }.map(\.id)
            }
            for id in gone { forgetArchivedWorkspace(id) }
            if let selected = app.selectedRemoteWorkspace?.id, gone.contains(selected) { app.selection = .home }
            await refreshCatalogue()
        default:
            break
        }
        return nil
    }
}
