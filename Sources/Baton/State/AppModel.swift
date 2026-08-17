import AppKit
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

/// An archive the app refused to carry out, waiting on the user.
///
/// It carries the report rather than a yes or no question, because "are you sure?" tells the user
/// nothing, and the whole point of stopping is that there is something specific to lose.
struct ArchiveRequest: Identifiable {
    let id = UUID()
    var workspace: Workspace
    var report: WorkspaceSafetyReport
    var deleteBranch: Bool?
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

    /// Selecting a workspace is the moment its live model should come into existence, rather than
    /// the moment some view body happens to ask for it. Doing it here keeps model creation out of
    /// the render pass entirely.
    var selection: SidebarSelection {
        get { storedSelection }
        set {
            storedSelection = newValue
            guard let id = newValue.workspaceID, workspaceModels[id] == nil,
                  let workspace = workspaces.first(where: { $0.id == id }) else { return }
            _ = model(for: workspace)
        }
    }

    private var storedSelection: SidebarSelection = .home

    var alert: BatonAlert?
    /// Non-nil while an archive is waiting for the user to confirm that the work it would destroy
    /// really is expendable. RootView presents the confirmation from this.
    var pendingArchive: ArchiveRequest?
    var searchQuery = ""
    var isCreatingWorkspace = false

    /// Live models for workspaces the user has visited this launch. Kept around so switching
    /// back to a workspace does not lose scroll position or a running agent.
    ///
    /// Deliberately outside observation. A view body asks for a model it has not seen before, and
    /// creating one has to be invisible to SwiftUI: a tracked write here would invalidate, from
    /// inside its own body, every view that had just read the dictionary. What the UI actually
    /// watches is the state inside each model, which stays observable.
    @ObservationIgnored private var workspaceModels: [String: WorkspaceModel] = [:]

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

    /// Quitting Baton has to take everything it started with it. macOS does not kill a process's
    /// children, so without this an agent keeps editing a worktree, a dev server keeps its port and
    /// a login shell keeps running, all reparented to launchd. Worse, the next launch marks those
    /// sessions idle and happily resumes them, which puts two `claude` processes on one session.
    func shutdownEverything() async {
        refreshTask?.cancel()
        refreshTask = nil

        let models = Array(workspaceModels.values)
        // Signal every agent first, so the SIGTERM escalations all run at the same time rather than
        // one after another.
        for model in models { model.stopEverything() }

        // The shells and the agents wait on their own escalations, so the two waits overlap rather
        // than queue. Each model returns as soon as its agent is gone, which is immediately for all
        // but the one that ignored SIGTERM.
        async let terminals: Void = TerminalSessionStore.shared.shutdownAll()
        for model in models { await model.shutdown() }
        await terminals
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
                // Nothing here is worth a git subprocess while the user is in another app, and an
                // agent editing the worktree is exactly when this loop is most likely to collide
                // with a lock it has no business waiting for.
                guard NSApp?.isActive ?? true else { continue }
                await self.refreshDiffStats()
            }
        }
    }

    func refreshDiffStats() async {
        guard let manager, let store else { return }
        let current = workspaces
        for workspace in current {
            guard !Task.isCancelled else { return }
            // A worktree that has been removed outside Baton would make git walk up to the parent
            // repository and answer about the wrong tree.
            guard FileManager.default.fileExists(atPath: workspace.path) else { continue }
            await Self.withTimeLimit(.seconds(5)) {
                await manager.refreshDiffStat(workspace: workspace)
            }
        }
        if let updated = try? await store.workspaces() {
            // Only reassign when something actually changed, to avoid pointless view updates.
            if updated != workspaces { workspaces = updated }
        }
    }

    /// Runs work with a deadline. One `git` blocked on an `index.lock`, which is routine while an
    /// agent commits, would otherwise stall the refresh loop for every workspace forever.
    /// Cancellation reaches the subprocess itself: `Shell.run` terminates it when its task is
    /// cancelled.
    private static func withTimeLimit(
        _ limit: Duration,
        _ work: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
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
    ///
    /// Called straight from view bodies, so it has to be free of observable writes on the hit path.
    /// The row is only pushed into the model when it differs, because assigning an identical
    /// `Workspace` still counts as a mutation to the Observation runtime.
    func model(for workspace: Workspace) -> WorkspaceModel {
        if let existing = workspaceModels[workspace.id] {
            if existing.workspace != workspace { existing.workspace = workspace }
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

    /// Whether a workspace has a running agent, without forcing a `WorkspaceModel` into
    /// existence. Sidebar rows ask this for every visible workspace on every redraw, and
    /// `model(for:)` mutates observable state, so calling that from a view body would schedule
    /// an extra render pass per row.
    func isRunning(_ workspace: Workspace) -> Bool {
        workspaceModels[workspace.id]?.isRunning ?? false
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

            model.startSetupThenSend(prompt: prompt, repo: repo)
            return workspace
        } catch {
            alert = BatonAlert(title: "Could not create the workspace", message: "\(error)")
            return nil
        }
    }

    /// Archives when there is nothing to lose, and asks first when there is.
    ///
    /// Nothing is torn down before the decision: a refused archive used to take the workspace's
    /// shells and dev servers with it anyway, which is a strange thing to happen after being told
    /// the workspace was too valuable to remove.
    func archive(_ workspace: Workspace, deleteBranch: Bool? = nil) async {
        guard let manager, let repo = repo(for: workspace) else { return }

        let report = try? await manager.safetyReport(workspace: workspace, repo: repo)
        // No report means git could not answer, and that is not a licence to delete. Treat it the
        // same as unsafe and let the user look at what it says.
        guard let report, report.isSafeToDiscard else {
            pendingArchive = ArchiveRequest(
                workspace: workspace,
                report: report ?? WorkspaceSafetyReport(hasUncommittedChanges: true),
                deleteBranch: deleteBranch
            )
            return
        }

        await performArchive(workspace, repo: repo, deleteBranch: deleteBranch, force: false)
    }

    /// The user has seen exactly what would be destroyed and asked for it anyway.
    func confirmPendingArchive() async {
        guard let request = pendingArchive, let repo = repo(for: request.workspace) else { return }
        pendingArchive = nil
        await performArchive(
            request.workspace, repo: repo, deleteBranch: request.deleteBranch, force: true
        )
    }

    func cancelPendingArchive() {
        pendingArchive = nil
    }

    private func performArchive(
        _ workspace: Workspace,
        repo: Repo,
        deleteBranch: Bool?,
        force: Bool
    ) async {
        guard let manager else { return }

        // The agents go first: they are the ones writing to the worktree that is about to be
        // removed. The shells and dev servers only go once the removal has actually happened, so a
        // failing archive script does not cost the user their terminals for nothing.
        workspaceModels[workspace.id]?.teardown()

        do {
            try await manager.archive(
                workspace: workspace, repo: repo, deleteBranch: deleteBranch, force: force
            )
            // The worktree is gone from disk now. Its shells are sitting in a directory that no
            // longer exists and its dev servers are still holding their ports, and nothing else in
            // the app will ever come back for them.
            await TerminalSessionStore.shared.discard(workspaceID: workspace.id)
            workspaceModels[workspace.id] = nil
            if selection.workspaceID == workspace.id { selection = .home }
            await reload()
        } catch let error as WorkspaceError {
            switch error {
            case .archiveScriptFailed(let status, let output):
                // Worth its own wording: the manager stops before removing anything, so the user
                // needs to hear that the workspace is still there rather than fear the worst.
                alert = BatonAlert(
                    title: "The archive script for \(workspace.name) failed",
                    message: "Nothing was removed and the workspace is intact. "
                        + "The script exited with status \(status).\n\n"
                        + output.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            case .unsafeToArchive(let report):
                // Only reachable when the worktree changed between the check and the archive.
                pendingArchive = ArchiveRequest(
                    workspace: workspace, report: report, deleteBranch: deleteBranch
                )
            default:
                alert = BatonAlert(title: "Could not archive the workspace", message: "\(error)")
            }
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
