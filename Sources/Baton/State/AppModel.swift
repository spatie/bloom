import SwiftUI
import Observation
import BatonCore

enum SidebarSelection: Hashable {
    case home
    case search
    case workspace(String)

    var workspaceID: String? {
        if case .workspace(let id) = self { return id }
        return nil
    }
}

struct BatonAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The root of the app's state. Owns the store, the repo and workspace lists, and one
/// `WorkspaceModel` per workspace the user has opened.
///
/// Everything here is main-actor isolated. `Store` is an actor, so every read is an await, and
/// the pattern throughout is: mutate through the store, then reload the affected slice.
@MainActor
@Observable
final class AppModel {
    private(set) var store: Store?
    private(set) var manager: WorkspaceManager?

    private(set) var repos: [Repo] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var isLoaded = false

    var selection: SidebarSelection = .home
    var alert: BatonAlert?
    var searchQuery = ""
    var isCreatingWorkspace = false

    /// Live models for workspaces the user has visited this launch. Kept around so switching
    /// back to a workspace does not lose scroll position or a running agent.
    private var workspaceModels: [String: WorkspaceModel] = [:]

    private var refreshTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func bootstrap() async {
        guard store == nil else { return }
        do {
            let store = try Store(path: try Store.defaultPath())
            self.store = store
            self.manager = WorkspaceManager(store: store)
            try await store.resetRunningSessions()
            await reload()
            isLoaded = true
        } catch {
            alert = BatonAlert(title: "Could not open the Baton database", message: "\(error)")
            isLoaded = true
        }

        Task { await GitHubIdentity.resolve() }
        startBackgroundRefresh()
    }

    func reload() async {
        guard let store else { return }
        do {
            repos = try await store.repos()
            workspaces = try await store.workspaces()
        } catch {
            alert = BatonAlert(title: "Could not read workspaces", message: "\(error)")
        }
    }

    /// Refreshes diff stats for every active workspace so the sidebar counts stay honest even
    /// when the user edits files outside Baton.
    private func startBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard let self else { return }
                await self.refreshDiffStats()
            }
        }
    }

    func refreshDiffStats() async {
        guard let manager, let store else { return }
        let current = workspaces
        for workspace in current {
            await manager.refreshDiffStat(workspace: workspace)
        }
        if let updated = try? await store.workspaces() {
            // Only reassign when something actually changed, to avoid pointless view updates.
            if updated != workspaces { workspaces = updated }
        }
    }

    // MARK: - Derived

    func repo(for workspace: Workspace) -> Repo? {
        repos.first { $0.id == workspace.repoID }
    }

    func workspaces(in repo: Repo) -> [Workspace] {
        workspaces
            .filter { $0.repoID == repo.id }
            .sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

    var selectedWorkspace: Workspace? {
        guard let id = selection.workspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// The live model for a workspace, created on first use.
    func model(for workspace: Workspace) -> WorkspaceModel {
        if let existing = workspaceModels[workspace.id] {
            existing.workspace = workspace
            return existing
        }
        let model = WorkspaceModel(workspace: workspace, app: self)
        workspaceModels[workspace.id] = model
        return model
    }

    var selectedModel: WorkspaceModel? {
        selectedWorkspace.map { model(for: $0) }
    }

    /// Workspaces with an agent currently running, for the dock badge and the window title.
    var runningCount: Int {
        workspaceModels.values.count { $0.isRunning }
    }

    // MARK: - Repos

    func addRepository(at path: String) async {
        guard let manager else { return }
        do {
            _ = try await manager.addRepository(at: path)
            await reload()
        } catch {
            alert = BatonAlert(title: "Could not add that folder", message: "\(error)")
        }
    }

    func removeRepository(_ repo: Repo) async {
        guard let store else { return }
        do {
            try await store.deleteRepo(id: repo.id)
            await reload()
        } catch {
            alert = BatonAlert(title: "Could not remove the project", message: "\(error)")
        }
    }

    func toggleCollapsed(_ repo: Repo) async {
        guard let store else { return }
        _ = try? await store.upsert(repo.with { $0.collapsed.toggle() })
        await reload()
    }

    func rename(_ repo: Repo, to name: String) async {
        guard let store, !name.isEmpty else { return }
        _ = try? await store.upsert(repo.with { $0.name = name })
        await reload()
    }

    // MARK: - Workspaces

    /// Creates the worktree, selects it, kicks off setup, and sends the first prompt once setup
    /// finishes. The whole flow is one call because that is how it reads to the user.
    @discardableResult
    func createWorkspace(in repo: Repo, prompt: String, baseBranch: String? = nil) async -> Workspace? {
        guard let manager, let store else { return nil }
        isCreatingWorkspace = true
        defer { isCreatingWorkspace = false }

        do {
            let workspace = try await manager.createWorkspace(
                repo: repo, prompt: prompt, baseBranch: baseBranch
            )
            await reload()
            selection = .workspace(workspace.id)

            let model = model(for: workspace)
            let session = try await store.upsert(Session(
                workspaceID: workspace.id,
                title: Git.title(from: prompt, maxLength: 40)
            ))
            await model.reloadSessions()
            model.activeSessionID = session.id

            Task { await model.runSetupThenSend(prompt: prompt, repo: repo) }
            return workspace
        } catch {
            alert = BatonAlert(title: "Could not create the workspace", message: "\(error)")
            return nil
        }
    }

    func archive(_ workspace: Workspace, deleteBranch: Bool? = nil) async {
        guard let manager, let repo = repo(for: workspace) else { return }
        workspaceModels[workspace.id]?.stopEverything()
        do {
            try await manager.archive(workspace: workspace, repo: repo, deleteBranch: deleteBranch)
            workspaceModels[workspace.id] = nil
            if selection.workspaceID == workspace.id { selection = .home }
            await reload()
        } catch {
            alert = BatonAlert(title: "Could not archive the workspace", message: "\(error)")
        }
    }

    func rename(_ workspace: Workspace, to name: String) async {
        guard let store, !name.isEmpty else { return }
        _ = try? await store.upsert(workspace.with { $0.name = name })
        await reload()
    }

    func togglePinned(_ workspace: Workspace) async {
        guard let store else { return }
        _ = try? await store.upsert(workspace.with { $0.pinned.toggle() })
        await reload()
    }

    func markRead(_ workspace: Workspace) async {
        guard let store, workspace.unread else { return }
        _ = try? await store.upsert(workspace.with { $0.unread = false })
        await reload()
    }

    func reorder(_ workspace: Workspace, to index: Int) async {
        guard let store, let repo = repo(for: workspace) else { return }
        var siblings = workspaces(in: repo)
        guard let from = siblings.firstIndex(where: { $0.id == workspace.id }) else { return }
        let moved = siblings.remove(at: from)
        siblings.insert(moved, at: min(max(index, 0), siblings.count))
        for (order, var sibling) in siblings.enumerated() where sibling.sortOrder != order {
            sibling.sortOrder = order
            _ = try? await store.upsert(sibling)
        }
        await reload()
    }

    // MARK: - Navigation

    func selectNextWorkspace(offset: Int) {
        let ordered = repos.flatMap { workspaces(in: $0) }
        guard !ordered.isEmpty else { return }
        guard let current = selection.workspaceID,
              let index = ordered.firstIndex(where: { $0.id == current }) else {
            selection = .workspace(ordered[0].id)
            return
        }
        let next = (index + offset + ordered.count) % ordered.count
        selection = .workspace(ordered[next].id)
    }

    /// The next workspace with unread agent output, so the user can hop through what finished
    /// while they were elsewhere.
    func selectNextUnread() {
        let ordered = repos.flatMap { workspaces(in: $0) }
        guard let target = ordered.first(where: { $0.unread && $0.id != selection.workspaceID })
            ?? ordered.first(where: \.unread) else { return }
        selection = .workspace(target.id)
    }

    // MARK: - Search

    struct SearchHit: Identifiable {
        var id: String { workspace.id }
        var workspace: Workspace
        var repo: Repo?
        var reason: String
    }

    func search(_ query: String) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return workspaces.compactMap { workspace in
            let repo = repo(for: workspace)
            if workspace.name.lowercased().contains(needle) {
                return SearchHit(workspace: workspace, repo: repo, reason: workspace.name)
            }
            if workspace.branch.lowercased().contains(needle) {
                return SearchHit(workspace: workspace, repo: repo, reason: workspace.branch)
            }
            if let repo, repo.name.lowercased().contains(needle) {
                return SearchHit(workspace: workspace, repo: repo, reason: repo.name)
            }
            return nil
        }
    }
}
