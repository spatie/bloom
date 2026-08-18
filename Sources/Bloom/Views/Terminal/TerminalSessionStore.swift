import SwiftUI
import Observation
import BloomCore

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

    private var terminals: [String: BloomTerminalView] = [:]
    private var runSessions: [String: RunScriptSession] = [:]
    private var loading: Set<String> = []

    /// Which workspace each pane belongs to, so closing one can name its tmux session without
    /// walking back through tabs that may already be gone.
    private var paneOwner: [String: String] = [:]

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
        closePanes(of: tab.id, workspaceID: tab.workspaceID)

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

    /// Stops one split pane. The shell's whole process group goes, not just the shell: a pty child
    /// is a session leader, so the group is where the `npm run dev` the user started in that pane
    /// actually lives, and it would otherwise be reparented to launchd still holding its port.
    ///
    /// A tmux-backed pane needs the session killed as well. Signalling the pane only reaches the
    /// tmux *client*, which is a detach, and detaching is the opposite of what closing a pane means.
    func closePane(id: String) {
        if let workspaceID = paneOwner.removeValue(forKey: id) {
            let persistence = self.persistence
            Task { await persistence?.kill(workspaceID: workspaceID, paneIDs: [id]) }
        }
        guard let view = terminals[id] else { return }
        signal(SIGTERM, toGroupOf: view)
        view.shutdown()
        terminals[id] = nil
    }

    /// Every pane of a tab that is going away, and the shape it was split into.
    ///
    /// The workspace is passed when the caller knows it, because a tab can be closed from the strip
    /// without ever having been drawn, and a pane that was never drawn has no owner recorded.
    func closePanes(of ownerID: String, workspaceID: String? = nil) {
        for pane in TerminalSplitStore.shared.panes(of: ownerID) {
            if let workspaceID { paneOwner[pane] = workspaceID }
            closePane(id: pane)
        }
        TerminalSplitStore.shared.discard(ownerID: ownerID)
    }

    /// The live shell for a tab, forked on first use and reused forever after.
    func terminal(
        for tab: TerminalTab,
        workspace: Workspace,
        repo: Repo?,
        port: Int
    ) -> BloomTerminalView {
        if let existing = terminals[tab.id] { return existing }

        let view = BloomTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        var extra: [String: String] = [:]
        if let repo, let store = repoStore {
            extra = WorkspaceManager(store: store).environment(
                for: workspace, repo: repo, port: port
            )
        }

        // `tab.id` is the pane id here: a split hands each pane a `TerminalTab` carrying its own id,
        // and an unsplit tab is its own single pane.
        paneOwner[tab.id] = workspace.id
        if let persistence, let command = persistence.command,
           let session = persistence.decision(workspaceID: workspace.id, paneID: tab.id).session {
            view.start(TerminalLaunch.tmux(
                command: command, session: session, directory: workspace.path, extra: extra
            ))
        } else {
            view.start(TerminalLaunch.loginShell(directory: workspace.path, extra: extra))
        }

        terminals[tab.id] = view
        return view
    }

    /// `WorkspaceManager` needs a store only to exist, so the panel hands one over once and every
    /// terminal after that can build its environment without threading a store through the views.
    private var repoStore: Store?

    /// The tmux server, when there is one to talk to. Built from the database path so a throwaway
    /// instance pointed at `BLOOM_DB_PATH` gets its own socket and cannot sweep the real one's
    /// sessions.
    private(set) var persistence: TerminalPersistence?

    private var didSweepOrphans = false

    func useStore(_ store: Store?) {
        if repoStore == nil { repoStore = store }
        ensurePersistence()
        sweepOrphanedSessions()
    }

    /// Built on demand rather than at init, because archiving a workspace has to be able to kill its
    /// sessions on a launch where no terminal panel was ever opened and no store was handed over.
    private func ensurePersistence() {
        guard persistence == nil, let path = repoStore?.path ?? (try? Store.defaultPath()) else {
            return
        }
        persistence = TerminalPersistence(databasePath: path)
    }

    /// The launch sweep, run once, the first time anything hands over a store.
    ///
    /// It is deliberately not on the critical path of drawing a terminal: a pane that starts before
    /// the sweep finishes is attaching to its own session by name, which the sweep will have found
    /// reachable and left alone.
    private func sweepOrphanedSessions() {
        // The store is part of the guard rather than of the task: without it there is no way to
        // know which panes are live, and marking the sweep done would mean it never ran at all.
        guard !didSweepOrphans, repoStore != nil, let persistence, persistence.isAvailable else {
            return
        }
        didSweepOrphans = true

        Task { [weak self] in
            await persistence.refresh()
            guard let self, let store = self.repoStore,
                  let workspaces = try? await store.workspaces() else { return }

            // Every pane Bloom can still reach: each tab of each workspace still in the database,
            // expanded through the split layout that tab was last left in.
            var live: Set<String> = []
            for workspace in workspaces {
                let tabs = (try? await store.terminalTabs(workspaceID: workspace.id)) ?? []
                for tab in tabs { live.formUnion(TerminalSplitStore.shared.panes(of: tab.id)) }
            }
            await persistence.sweepOrphans(livePaneIDs: live)
        }
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
    ///
    /// Awaitable because archiving deletes the worktree straight after. A shell whose cwd has just
    /// been removed, or a dev server still holding its port, is exactly what should not outlive the
    /// workspace it belonged to.
    ///
    /// Every tmux session of this workspace goes first and unconditionally, whatever the persistence
    /// setting says and whether or not this launch ever drew the pane that owns it. A shell sitting
    /// in a worktree that is being deleted is the hazard, and the setting has nothing to say about
    /// it. The sessions are matched by name, so this holds even for a tab that was never loaded.
    func discard(workspaceID: String) async {
        ensurePersistence()
        await persistence?.killEverything(workspaceID: workspaceID)

        var views: [BloomTerminalView] = []
        for tab in tabs(for: workspaceID) {
            // Every pane of the tab, which for a tab nobody split is the tab's own shell.
            for pane in TerminalSplitStore.shared.panes(of: tab.id) {
                if let view = terminals[pane] { views.append(view) }
                terminals[pane] = nil
                paneOwner[pane] = nil
            }
            TerminalSplitStore.shared.discard(ownerID: tab.id)
        }
        tabsByWorkspace[workspaceID] = nil

        var scripts: [RunScriptSession] = []
        for (key, session) in runSessions where key.hasPrefix("\(workspaceID)/") {
            scripts.append(session)
            runSessions[key] = nil
        }

        await stop(terminals: views, runScripts: scripts)
    }

    /// The quit path: every shell and every run script this launch started, whichever workspace
    /// they belong to. macOS does not kill a process's children, so anything still alive here gets
    /// reparented to launchd and keeps its ports for the rest of the day.
    ///
    /// No tmux session is killed here, and that is the feature. A tmux-backed pane's pty child is a
    /// *client*, and the server is daemonised into its own session, so signalling the client's
    /// process group detaches rather than terminates. The shell and everything the user started in
    /// it stay alive for the next launch to pick back up.
    func shutdownAll() async {
        let views = Array(terminals.values)
        let scripts = Array(runSessions.values)
        terminals.removeAll()
        runSessions.removeAll()
        tabsByWorkspace.removeAll()
        paneOwner.removeAll()
        await stop(terminals: views, runScripts: scripts)
    }

    /// SIGTERM to every process group, a bounded wait, then SIGKILL to whatever is left.
    private func stop(terminals views: [BloomTerminalView], runScripts scripts: [RunScriptSession]) async {
        // Only shells that are still running get signalled. A shell the user exited long ago has had
        // its pid reaped, and macOS hands pids out again, so signalling that number now could land
        // on somebody else's process group.
        let live = views.filter { $0.process?.running == true }
        guard !live.isEmpty || !scripts.isEmpty else { return }

        for view in live {
            signal(SIGTERM, toGroupOf: view)
            view.shutdown()
        }
        for script in scripts { script.stop() }

        // A moment for SIGTERM to be taken. A shell goes immediately, a dev server usually wants to
        // close its listeners first.
        try? await Task.sleep(for: .milliseconds(250))
        await waitForExit(of: scripts, upTo: .seconds(3.25))

        // Anything that sat through SIGTERM is out of chances. A run script escalates to SIGKILL on
        // its own after three seconds, so this second round is really for the shells. Their pids are
        // still safe to name: `terminate()` stops the app from reaping them, so nothing has reused
        // the number in the meantime.
        for view in live { signal(SIGKILL, toGroupOf: view) }
    }

    /// Signals the shell's whole process group rather than the shell alone. A pty child is a
    /// session leader, so its group holds everything the user started by hand in that terminal, and
    /// those are the processes that survive a quit and keep a port bound.
    private func signal(_ number: Int32, toGroupOf view: BloomTerminalView) {
        let pid = view.process?.shellPid ?? 0
        guard pid > 0 else { return }
        killpg(pid, number)
    }

    /// Polls rather than awaits because a run script owns its process privately. It returns as soon
    /// as everything has gone, which is the normal case within a frame or two.
    private func waitForExit(of scripts: [RunScriptSession], upTo limit: Duration) async {
        guard scripts.contains(where: \.isRunning) else { return }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if !scripts.contains(where: \.isRunning) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
