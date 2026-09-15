import AppKit
import Observation
import BloomCore
import BloomClient

/// Mac-only selection and filesystem access wrap the shared client session. Mutation review,
/// revision checks and uncertain-request recovery remain identical on Mac, iPad and iPhone.
@MainActor @Observable
final class ServerSkillsModel {
    let server: ServerWindowModel
    private(set) var session: ServerSkillsSession?
    private(set) var isReadingFolder = false
    private(set) var localFailure: String?
    private(set) var projectScope: WorkspaceID?
    private(set) var projectScopeName: String?
    private var profile: String?
    private var generation: Int?

    init(server: ServerWindowModel) { self.server = server }

    func refresh() async {
        let current = server.connectionProfile?.id
        if profile != current {
            session = nil; localFailure = nil; profile = current; generation = nil
            projectScope = nil; projectScopeName = nil
        }
        guard server.isConnected, let service = server.uiBridgeService() else { return }
        if let session {
            if generation != server.connectionGeneration { session.reconnect(client: service.client) }
        } else {
            let workspace = server.selectedWorkspace
            projectScope = workspace?.id; projectScopeName = workspace?.name
            session = ServerSkillsSession(client: service.client, workspaceID: projectScope)
        }
        generation = server.connectionGeneration
        await session?.refresh()
    }

    var canUseCurrentWorkspace: Bool {
        server.isConnected && server.selectedWorkspace != nil && server.selectedWorkspace?.id != projectScope
            && session?.activity == .idle && session?.pendingMutationID == nil && !isReadingFolder
    }

    /// Scope changes are explicit and never replace a session holding an unconfirmed mutation.
    func useCurrentWorkspace() async {
        guard canUseCurrentWorkspace, let workspace = server.selectedWorkspace,
              let service = server.uiBridgeService() else { return }
        projectScope = workspace.id; projectScopeName = workspace.name
        session = ServerSkillsSession(client: service.client, workspaceID: workspace.id)
        generation = server.connectionGeneration
        await session?.refresh()
    }

    func reconnect() async {
        guard !server.isMaintainingServer else { return }
        await server.connect()
        await refresh()
    }

    func importFolder() async -> Bool {
        guard let session, session.canMutate, !isReadingFolder else { return false }
        let originalProfile = server.connectionProfile?.id
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false; panel.resolvesAliases = false
        panel.prompt = "Review Skill"
        panel.message = "Choose one skill folder containing SKILL.md. Hidden files and credentials are not imported."
        guard await panel.present() == .OK, let folder = panel.url else { return false }
        guard originalProfile == server.connectionProfile?.id, self.session === session, server.isConnected else {
            localFailure = "The server connection changed. Choose the skill folder again."
            return false
        }
        localFailure = nil; isReadingFolder = true
        defer { isReadingFolder = false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            let files = try await Task.detached { try ServerSkillFolderImport.read(folder) }.value
            try Task.checkCancellation()
            guard originalProfile == server.connectionProfile?.id, self.session === session, server.isConnected else {
                localFailure = "The server connection changed. Nothing was uploaded."
                return false
            }
            let prepared = await session.previewImport(files: files)
            return prepared && self.session === session && originalProfile == server.connectionProfile?.id
        } catch is CancellationError {
            return false
        } catch {
            localFailure = ServerSetupDiagnostics.sanitise(error.localizedDescription)
            return false
        }
    }
}
