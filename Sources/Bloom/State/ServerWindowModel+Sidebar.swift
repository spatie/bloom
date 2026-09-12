import Foundation
import BloomCore

/// The sidebar uses normal rows and menus, with mutations directed to the owning server.
extension ServerWindowModel {
    var sidebarRepositories: [Repo] {
        (catalogue?.repositories ?? []).map { repo in
            var row = repo
            row.collapsed = sidebarCollapsed.contains(repo.id)
            // Server artwork paths must never be resolved against the Mac filesystem.
            row.iconPath = nil
            row.iconSource = .monogram
            return row
        }
    }

    func loadSidebarPreferences() {
        guard !sidebarCollapseLoaded else { return }
        sidebarCollapseLoaded = true
        sidebarCollapsed = Set((UserDefaults.standard.stringArray(forKey: sidebarCollapseKey) ?? []).map(RepoID.init))
    }

    private var sidebarCollapseKey: String { "server.sidebar.collapsed." + String(reflecting: endpoint) }

    func toggleCollapsed(_ repo: Repo) {
        if !sidebarCollapsed.insert(repo.id).inserted { sidebarCollapsed.remove(repo.id) }
        UserDefaults.standard.set(sidebarCollapsed.map(\.rawValue), forKey: sidebarCollapseKey)
    }

    func isRunning(_ workspace: Workspace) -> Bool {
        catalogue?.sessions.contains { $0.workspaceID == workspace.id && (existingConversation($0.id)?.isRunning == true || $0.state == .running) } == true
    }

    func isAwaitingPermission(_ workspace: Workspace) -> Bool {
        catalogue?.sessions.contains { $0.workspaceID == workspace.id && $0.state == .waiting } == true
    }

    func refreshCatalogue() async {
        do {
            if case .catalogue(let value) = try await read(.catalogue) { receiveSidebarCatalogue(value) }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func updateWorkspace(_ workspace: Workspace, action: ServerWorkspaceAction) async {
        guard await perform(.workspace(workspaceID: workspace.id, action: action)) != nil else { return }
        await refreshCatalogue()
    }

    func updateProject(_ repo: Repo, action: ServerProjectAction) async {
        guard await perform(.project(repoID: repo.id, action: action)) != nil else { return }
        await refreshCatalogue()
    }

    func archive(_ workspace: Workspace, app: AppModel, alwaysConfirm: Bool,
                 present: @escaping (ArchiveRequest) -> Void) async {
        guard !archivingWorkspaceIDs.contains(workspace.id), let endpoint else { return }
        guard case .archivePreview(let preview) = await perform(.workspace(workspaceID: workspace.id, action: .archivePreview)), self.endpoint == endpoint else { return }
        let request = preview.request
        archiveConfirmations[request.id] = (endpoint, preview)
        if alwaysConfirm || request.severity != .routine { present(request) } else { await confirmArchive(request, app: app, present: present) }
    }

    func confirmArchive(_ request: ArchiveRequest, app: AppModel,
                        present: @escaping (ArchiveRequest) -> Void) async {
        guard let (capturedEndpoint, preview) = archiveConfirmations.removeValue(forKey: request.id), endpoint == capturedEndpoint else {
            error = "The server connection changed. Choose Archive again."
            return
        }
        let id = preview.workspace.id
        guard archivingWorkspaceIDs.insert(id).inserted else { return }
        defer { archivingWorkspaceIDs.remove(id) }
        let result = await perform(.workspace(workspaceID: id, action: .archive(confirmation: preview.id)))
        guard endpoint == capturedEndpoint else { return }
        switch result {
        case .archivePreview(let fresh):
            let next = fresh.request
            archiveConfirmations[next.id] = (capturedEndpoint, fresh)
            present(next)
        case .accepted:
            forgetArchivedWorkspace(id)
            if app.selectedRemoteWorkspace?.id == id { app.selection = .home }
            await refreshCatalogue()
        default: break
        }
    }

    func restore(_ workspace: Workspace, app: AppModel) async {
        guard await perform(.workspace(workspaceID: workspace.id, action: .restore)) != nil else { return }
        await refreshCatalogue()
        app.selection = .remoteWorkspace(workspace.id)
    }
}
