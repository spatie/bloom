import SwiftUI
import Observation
import BatonCore

/// The one place that owns live shells and live run scripts.
///
/// SwiftUI rebuilds views constantly, and a `LocalProcessTerminalView` that gets rebuilt takes the
/// user's shell and their whole scrollback with it. So nothing about a terminal lives in a view:
/// the views are created once here, keyed by terminal tab id, and handed back unchanged for as
/// long as the app runs. The same reasoning applies to a dev server started from a run script,
/// which has to survive switching tabs, collapsing the panel and switching workspaces.
@MainActor
@Observable
final class TerminalSessionStore {
    static let shared = TerminalSessionStore()

    /// Terminal tabs per workspace, mirroring the `terminal_tabs` table so the UI never has to
    /// wait on SQLite to draw the tab strip.
    private(set) var tabsByWorkspace: [String: [TerminalTab]] = [:]

    private var terminals: [String: BatonTerminalView] = [:]
    private var runSessions: [String: RunScriptSession] = [:]
    private var loading: Set<String> = []

    private init() {}

    // MARK: - Tabs

    func tabs(for workspaceID: String) -> [TerminalTab] {
        tabsByWorkspace[workspaceID] ?? []
    }

    /// Restores the persisted tabs for a workspace. A workspace that has never been opened gets
    /// one tab called "Terminal", which is what a user expects to find waiting for them.
    func load(workspaceID: String, store: Store?) async {
        guard tabsByWorkspace[workspaceID] == nil, !loading.contains(workspaceID) else { return }
        loading.insert(workspaceID)
        defer { loading.remove(workspaceID) }

        var tabs: [TerminalTab] = []
        if let store {
            tabs = (try? await store.terminalTabs(workspaceID: workspaceID)) ?? []
        }
        if tabs.isEmpty {
            let tab = TerminalTab(workspaceID: workspaceID, title: "Terminal", sortOrder: 0)
            if let store { try? await store.upsert(tab) }
            tabs = [tab]
        }
        tabsByWorkspace[workspaceID] = tabs
    }

    @discardableResult
    func addTab(workspaceID: String, store: Store?) async -> TerminalTab {
        var tabs = tabs(for: workspaceID)
        let tab = TerminalTab(
            workspaceID: workspaceID,
            title: nextTitle(in: tabs),
            sortOrder: (tabs.map(\.sortOrder).max() ?? -1) + 1
        )
        tabs.append(tab)
        tabsByWorkspace[workspaceID] = tabs
        if let store { try? await store.upsert(tab) }
        return tab
    }

    /// Closing the last tab immediately opens a fresh one, because a bottom panel with no terminal
    /// in it is a dead end.
    @discardableResult
    func closeTab(_ tab: TerminalTab, store: Store?) async -> [TerminalTab] {
        terminals[tab.id]?.shutdown()
        terminals[tab.id] = nil

        var tabs = tabs(for: tab.workspaceID).filter { $0.id != tab.id }
        tabsByWorkspace[tab.workspaceID] = tabs
        if let store { try? await store.deleteTerminalTab(id: tab.id) }

        if tabs.isEmpty {
            let replacement = await addTab(workspaceID: tab.workspaceID, store: store)
            tabs = [replacement]
        }
        return tabs
    }

    func rename(_ tab: TerminalTab, to title: String, store: Store?) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var tabs = tabs(for: tab.workspaceID)
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index].title = trimmed
        tabsByWorkspace[tab.workspaceID] = tabs
        if let store { try? await store.upsert(tabs[index]) }
    }

    private func nextTitle(in tabs: [TerminalTab]) -> String {
        var index = tabs.count + 1
        let taken = Set(tabs.map(\.title))
        while taken.contains("Terminal \(index)") { index += 1 }
        return tabs.isEmpty ? "Terminal" : "Terminal \(index)"
    }

    // MARK: - Terminals

    /// The live shell for a tab, forked on first use and reused forever after.
    func terminal(
        for tab: TerminalTab,
        workspace: Workspace,
        repo: Repo?,
        port: Int
    ) -> BatonTerminalView {
        if let existing = terminals[tab.id] { return existing }

        let view = BatonTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        var extra: [String: String] = [:]
        if let repo, let store = repoStore {
            extra = WorkspaceManager(store: store).environment(
                for: workspace, repo: repo, port: port
            )
        }
        view.start(TerminalLaunch.loginShell(directory: workspace.path, extra: extra))
        terminals[tab.id] = view
        return view
    }

    /// `WorkspaceManager` needs a store only to exist, so the panel hands one over once and every
    /// terminal after that can build its environment without threading a store through the views.
    private var repoStore: Store?

    func useStore(_ store: Store?) {
        if repoStore == nil { repoStore = store }
    }

    // MARK: - Run scripts

    func runSession(for script: RunScript, workspace: Workspace) -> RunScriptSession {
        let key = "\(workspace.id)/\(script.id)"
        if let existing = runSessions[key] {
            existing.script = script
            return existing
        }
        let session = RunScriptSession(script: script, workspace: workspace)
        runSessions[key] = session
        return session
    }

    // MARK: - Teardown

    /// Called when a workspace goes away for good. Nothing calls this on a plain tab switch, which
    /// is the entire point of this class.
    func discard(workspaceID: String) {
        for tab in tabs(for: workspaceID) {
            terminals[tab.id]?.shutdown()
            terminals[tab.id] = nil
        }
        tabsByWorkspace[workspaceID] = nil
        for (key, session) in runSessions where key.hasPrefix("\(workspaceID)/") {
            session.stop()
            runSessions[key] = nil
        }
    }
}
