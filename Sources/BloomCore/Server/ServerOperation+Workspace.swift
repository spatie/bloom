import Foundation

/// Exhaustive operation routing keeps a newly added mutation from silently bypassing archive's
/// drain. Archive and restore own exclusive transitions, so neither acquires its own read ticket.
enum ServerWorkspaceMutation: Equatable {
    case workspace(WorkspaceID)
    case session(SessionID)
}

extension ServerOperation {
    var workspaceMutation: ServerWorkspaceMutation? {
        switch self {
        case .workspace(let id, let action):
            guard action.mutates else { return nil }
            switch action {
            case .archive, .restore: return nil
            default: return .workspace(id)
            }
        case .terminalStream(let id, _): return .workspace(id)
        case .send(let id, _, _), .setComposer(let id, _), .configure(let id, _, _, _),
             .closeSession(let id), .stop(let id), .answer(let id, _, _), .cancelQueued(let id, _),
             .renameSession(let id, _), .markRead(let id, _): return .session(id)
        case .uiBridge, .creation, .reviewSnapshot, .reviewPatch, .diagnostics, .hello, .previewAddress,
             .composer, .project, .catalogue, .create, .transcript, .changes, .patch, .file: return nil
        }
    }
}
