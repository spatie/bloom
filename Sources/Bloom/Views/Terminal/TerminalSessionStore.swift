import SwiftUI
import Observation
import BloomCore

/// The one place that owns live shells.
///
/// SwiftUI rebuilds views constantly, and a `LocalProcessTerminalView` that gets rebuilt takes the
/// user's shell and their whole scrollback with it. So nothing about a terminal lives in a view:
/// the views are created once here, keyed by pane id, and handed back unchanged for as long as the
/// app runs.
///
/// Which terminals a workspace HAS is not here and never was two things: it is `CenterTabStore`,
/// alongside the browsers and the review, because a terminal is a tab in the centre column like
/// any other. This owns the processes those tabs point at, and nothing else.
@MainActor
@Observable
final class TerminalSessionStore {
    static let shared = TerminalSessionStore()

    private var terminals: [String: BloomTerminalView] = [:]

    /// A command waiting for its pane's shell to exist, which is how a run script opens: a terminal
    /// tab named after the script, with the script's own command typed into it.
    ///
    /// Typed rather than exec'd, and that is deliberate. The command lands in the shell's history,
    /// so Ctrl+C then Up then Return restarts a dev server the way it does in any terminal, and
    /// when it exits the pane is still a shell rather than a pane that closes itself.
    private var pendingCommands: [String: String] = [:]

    /// Which workspace each pane belongs to, so closing one can name its tmux session without
    /// walking back through tabs that may already be gone.
    private var paneOwner: [String: String] = [:]

    private init() {}

    // MARK: - Terminals

    /// Queues a command for the pane that has not been drawn yet, so the shell runs it the moment
    /// it is forked. Nothing happens if the pane's shell already exists: a run script opens a tab
    /// of its own, and the tab is new every time.
    func run(_ command: String, inPaneID paneID: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingCommands[paneID] = trimmed
    }

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
        closedPanes.insert(id)
        guard let view = terminals[id] else { return }
        defer { terminals[id] = nil }

        // Nothing is signalled for a shell that has already ended. Its pid has been reaped, and
        // macOS hands pids out again, so naming that number now could land on a process group
        // belonging to somebody else entirely.
        guard view.process?.running == true else { return }
        // Read before the shell is terminated, so the escalation below has a number to name.
        let pid = view.process?.shellPid ?? 0

        // Before the signal, so the exit it causes is read as Bloom closing the pane rather than
        // as the shell ending by itself and asking for the pane to close a second time.
        view.willStop()
        hangUp(on: view)
        view.shutdown()

        // Anything that sat through a hangup is out of chances. The pid is still safe to name:
        // `terminate` cancels the app's own exit monitor, so nothing reaps the child and macOS
        // cannot have handed the number to somebody else in the meantime.
        guard pid > 0 else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            killpg(pid, SIGKILL)
        }
    }

    /// Tells a shell its terminal has gone.
    ///
    /// SIGHUP rather than SIGTERM alone, which is the fix for a real orphan: an interactive login
    /// shell ignores SIGTERM, so closing a tab left a zsh alive in the worktree, holding its pty
    /// and its working directory for the rest of the day, and holding whatever it had running.
    /// SIGHUP is what a terminal emulator sends when its window closes, and it is the one an
    /// interactive shell does not ignore. SIGTERM still follows it, for anything in the group that
    /// answers to that and not to a hangup.
    private func hangUp(on view: BloomTerminalView) {
        signal(SIGHUP, toGroupOf: view)
        signal(SIGTERM, toGroupOf: view)
    }

    /// Panes that have been closed, which is what stops one from forking a second shell on its way
    /// off screen.
    ///
    /// A view is not torn down the instant its pane goes: SwiftUI redraws on the next pass, and a
    /// tab whose last pane has just closed is drawn one more time before the strip catches up. That
    /// draw asks for its shell, finds the closed one gone, and forks a replacement into a worktree
    /// nobody is looking at. It kept its process group, its port and, with persistence on, its
    /// tmux session, and nothing ever closed it again because no tab named it any more.
    ///
    /// A pane id is a fresh uuid and is never reused, so remembering the ones that are over is
    /// enough, and each is one small string.
    private var closedPanes: Set<String> = []

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

        // A pane that is already over, drawn one last time before SwiftUI catches up. It gets an
        // empty terminal that forks nothing and is not filed under its id, so the draw after this
        // one drops it. See `closedPanes`.
        guard !closedPanes.contains(tab.id) else {
            view.willStop()
            return view
        }

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
        if let command = pendingCommands.removeValue(forKey: tab.id) { type(command, into: view) }
        return view
    }

    /// Types a command into a shell that has just been forked.
    ///
    /// After a beat, because the pty is ready before zsh is: bytes written into it in the same
    /// turn as the fork arrive before the line editor has been set up, and zsh's own startup then
    /// redraws over them. A tenth of a second is longer than any of that takes and is under what
    /// anybody reads as a delay. The command is still typed rather than exec'd, so a shell whose
    /// rc files run slower than this simply receives it a moment later.
    private func type(_ command: String, into view: BloomTerminalView) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard view.process?.running == true else { return }
            view.send(txt: command + "\n")
        }
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

            // Every pane Bloom can still reach: each terminal tab of each workspace still in the
            // database, expanded through the split layout that tab was last left in.
            var live: Set<String> = []
            for workspace in workspaces {
                for tab in CenterTabStore.shared.terminalTabIDs(for: workspace.id) {
                    live.formUnion(TerminalSplitStore.shared.panes(of: tab))
                }
            }
            await persistence.sweepOrphans(livePaneIDs: live)
        }
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

        let tabs = CenterTabStore.shared.terminalTabIDs(for: workspaceID)

        // Every shell of this workspace is told first that Bloom is the one ending it, because the
        // kill below reaches them without this app signalling anything: a tmux client whose server
        // destroys its session exits cleanly, and a clean exit is what closes a pane. Without this
        // a workspace being archived would spend the await closing its own tabs, and the strip
        // would open a replacement terminal for a worktree that is about to be deleted.
        for tab in tabs {
            for pane in TerminalSplitStore.shared.panes(of: tab) {
                terminals[pane]?.willStop()
            }
        }

        await persistence?.killEverything(workspaceID: workspaceID)

        var views: [BloomTerminalView] = []
        for tab in tabs {
            // Every pane of the tab, which for a tab nobody split is the tab's own shell.
            for pane in TerminalSplitStore.shared.panes(of: tab) {
                if let view = terminals[pane] { views.append(view) }
                terminals[pane] = nil
                paneOwner[pane] = nil
            }
            TerminalSplitStore.shared.discard(ownerID: tab)
        }

        await stop(views)
    }

    /// The quit path: every shell this launch started, whichever workspace it belongs to. macOS
    /// does not kill a process's children, so anything still alive here gets reparented to launchd
    /// and keeps its ports for the rest of the day.
    ///
    /// No tmux session is killed here, and that is the feature. A tmux-backed pane's pty child is a
    /// *client*, and the server is daemonised into its own session, so signalling the client's
    /// process group detaches rather than terminates. The shell and everything the user started in
    /// it stay alive for the next launch to pick back up.
    func shutdownAll() async {
        let views = Array(terminals.values)
        terminals.removeAll()
        paneOwner.removeAll()
        pendingCommands.removeAll()
        await stop(views)
    }

    /// A hangup to every process group, a bounded wait, then SIGKILL to whatever is left.
    private func stop(_ views: [BloomTerminalView]) async {
        // Only shells that are still running get signalled. A shell the user exited long ago has had
        // its pid reaped, and macOS hands pids out again, so signalling that number now could land
        // on somebody else's process group.
        let live = views.filter { $0.process?.running == true }
        guard !live.isEmpty else { return }

        for view in live {
            // Before the signal, for the reason spelled out in `closePane`.
            view.willStop()
            hangUp(on: view)
            view.shutdown()
        }

        // A moment for the signal to be taken. A shell goes immediately, a dev server started in
        // one usually wants to close its listeners first.
        try? await Task.sleep(for: .milliseconds(250))

        // Anything that sat through SIGTERM is out of chances. Their pids are still safe to name:
        // `terminate()` stops the app from reaping them, so nothing has reused the number in the
        // meantime.
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

}
