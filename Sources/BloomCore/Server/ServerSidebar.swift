import Foundation

public enum ServerProjectAction: Codable, Sendable, Equatable {
    case rename(String)
    case setHidden(Bool)
    case setAccent(String)
    case settings
    case saveSettings(edits: [SettingsEdit], expected: RepoSettings)
    case filesToCopy(patterns: [String])

    var mutates: Bool {
        switch self {
        case .settings, .filesToCopy: false
        case .rename, .setHidden, .setAccent, .saveSettings: true
        }
    }
}

/// The server retains the confirmation; a client can only acknowledge its opaque identifier.
public struct ServerArchivePreview: Codable, Sendable {
    public var id: UUID
    public var workspace: Workspace
    public var report: WorkspaceSafetyReport
    public var hazards: ArchiveHazards
    public var createdAt: Date

    public var request: ArchiveRequest {
        ArchiveRequest(workspace: workspace, report: report, deleteBranch: hazards.isDeletingBranch, hazards: hazards)
    }
}

enum ServerSidebar {
    static func project(_ action: ServerProjectAction, id: RepoID, store: Store) async throws -> ServerResult {
        guard let repo = try await store.repo(id: id) else { throw ServerFailure("This project is no longer available.") }
        switch action {
        case .rename(let title):
            let name = try name(title)
            _ = try await store.update(repoID: id) { $0.name = name }
        case .setHidden(let value): _ = try await store.update(repoID: id) { $0.hidden = value }
        case .setAccent(let hex):
            guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { throw ServerFailure("Choose a valid project colour.") }
            _ = try await store.update(repoID: id) { $0.accent = hex }
        case .settings: return .projectSettings(ServerProjectSettings.load(repo: repo.path))
        case .saveSettings(let edits, let expected):
            let current = SettingsLoader.load(repo: repo.path)
            guard current == expected else { throw ServerFailure("Project settings changed on the server. Reload them before saving again.") }
            let paths = try SettingsWriter.write(edits, repo: repo.path, settings: current)
            return .projectSettings(ServerProjectSettings.load(repo: repo.path, savedPaths: paths))
        case .filesToCopy(let patterns):
            return .filesToCopy(FilesToCopyResolver.resolve(patterns: patterns, in: repo.path))
        }
        return .accepted
    }

    static func name(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 1_024 else { throw ServerFailure("Enter a name between 1 and 1,024 bytes.") }
        return name
    }

    static func preview(workspace: Workspace, store: Store) async throws -> ServerArchivePreview {
        guard workspace.setupState != .running else { throw ServerFailure("Wait for workspace setup to finish before archiving.") }
        let sessions = try await store.sessions(workspaceID: workspace.id)
        for session in sessions where try await !store.pendingDeliveries(sessionID: session.id).isEmpty {
            throw ServerFailure("Handle this workspace's queued messages before archiving.")
        }
        guard let repo = try await store.repo(id: workspace.repoID) else { throw ServerFailure("This workspace's project is unavailable.") }
        let report = try await WorkspaceManager(store: store).safetyReport(workspace: workspace, repo: repo)
        let hazards = ArchiveHazards(
            isAgentRunning: sessions.contains { $0.state == .running || $0.state == .waiting },
            isDeletingBranch: SettingsLoader.load(repo: repo.path).deleteBranchOnArchive
        )
        return ServerArchivePreview(id: UUID(), workspace: workspace, report: report, hazards: hazards, createdAt: Date())
    }
}
