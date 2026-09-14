import Foundation
import Observation
import BloomCore

/// The one way a run script is started, whoever asks: the tab strip's `+`, the Workspace menu, or
/// a workspace opening with scripts set to autostart.
///
/// **Picking a script that is running shows it rather than starting a second copy.** A second
/// Vite fights the first for its port and the error it prints reads as a broken app, and a seed
/// that has finished is not running, so picking it again runs it again in its own tab with its
/// last output still above. That decision is `RunScriptPick`, in the core; this gathers the facts
/// it needs and carries out the answer.
///
/// It also holds what the workspace's notices need to outlive a redraw: the autostart question
/// standing for each workspace, and which settings warnings were dismissed this launch.
@MainActor
@Observable
final class RunScriptLauncher {
    static let shared = RunScriptLauncher()

    /// The autostart question standing for each workspace, until it is answered, with the project
    /// it is about so an answer in one workspace can close the same question in the others.
    private var asks: [WorkspaceID: (project: RepoID, notice: RunScriptAutostartNotice)] = [:]

    /// Settings warnings dismissed this launch, by the messages they carried. Not by workspace:
    /// every workspace of a project reads the same files, so waving one away in one workspace and
    /// meeting it again in the next would be the app arguing.
    private(set) var dismissedIssues: Set<[String]> = []

    /// Projects whose question was answered with Not Now, which holds for the rest of the launch.
    @ObservationIgnored private var snoozed: Set<RepoID> = []

    /// What autostart was last settled against for each workspace this launch, and the ones being
    /// settled right now, so the column's arrival and a setup run finishing cannot both start the
    /// same script. By signature rather than a flag; see `RunScriptAutostart.signature(of:)`.
    @ObservationIgnored private var settled: [WorkspaceID: [String]] = [:]
    @ObservationIgnored private var settling: Set<WorkspaceID> = []
    /// Workspaces whose settings changed again while they were being settled, so the change that
    /// arrived mid-settle is settled once the first one finishes rather than dropped.
    @ObservationIgnored private var resettle: Set<WorkspaceID> = []
    /// Every autostart command started in each workspace this launch, one
    /// `RunScriptAutostart.entry(of:)` each. A file that goes from one set to another and back
    /// would otherwise start the first set a second time, and a seed somebody marked to autostart
    /// would wipe their database again on an edit to an unrelated line. Once per command per launch
    /// is what autostart promised before settings could change under an open workspace.
    @ObservationIgnored private var autostarted: [WorkspaceID: Set<String>] = [:]

    private init() {}

    private var sessions: TerminalSessionStore { .shared }

    func ask(for workspaceID: WorkspaceID) -> RunScriptAutostartNotice? {
        asks[workspaceID]?.notice
    }

    // MARK: - Picking

    /// Whether this tab's command is running, as the poll last read it.
    func isRunning(_ tab: CenterTab) -> Bool {
        tab.runScriptID != nil && sessions.activity.state(inPane: tab.id).isRunning
    }

    /// A person picked the script. The tab it lands in is brought forward.
    func pick(_ script: RunScript, in model: WorkspaceModel) {
        Task { await start(script, in: model, bringForward: true) }
    }

    /// Starts a script, or shows it if it is already going.
    ///
    /// `bringForward` is false for autostart, which must never take the window from whatever the
    /// owner is reading: the script starts in its tab and the tab stays where it is in the strip.
    func start(_ script: RunScript, in model: WorkspaceModel, bringForward: Bool) async {
        let command = script.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = model.workspace.id
        CenterTabStore.shared.load(workspaceID: workspaceID)

        // Only tabs that still have the pane their command was typed into. A tab whose first pane
        // was closed after a split carries the id and no longer the shell, and choosing it would
        // open a replacement tab on every pick.
        let tabs = CenterTabStore.shared.tabs(for: workspaceID).filter {
            $0.kind == .terminal && TerminalSplitStore.shared.panes(of: $0.id).contains($0.id)
        }
        let carrying = tabs.filter { $0.runScriptID == script.id }
        await settleReadings(of: carrying, in: model)

        switch RunScriptPick.decide(
            runScript: script.id, tabs: tabs, scriptOf: \.runScriptID, isRunning: isRunning
        ) {
        case .focus(let tab):
            if bringForward { reveal(tab, in: model) }

        case .rerun(let tab):
            guard !command.isEmpty else { return }
            if sessions.retype(command, inPane: tab.id) {
                if bringForward { reveal(tab, in: model) }
            } else {
                await open(script, command: command, in: model, bringForward: bringForward)
            }

        case .open:
            guard !command.isEmpty else { return }
            await open(script, command: command, in: model, bringForward: bringForward)
        }
    }

    /// Makes sure each of these tabs has a shell and has been read once, before a decision is
    /// taken on whether its command is running.
    ///
    /// A tab restored from the last launch has no shell in this one until it is drawn, and when
    /// tmux held its session through the quit, what is in that session may well be the dev server
    /// still going. Asking the pick about it unread would answer "stopped, run it again", and the
    /// command would be typed into the running server.
    private func settleReadings(of tabs: [CenterTab], in model: WorkspaceModel) async {
        guard !tabs.isEmpty else { return }
        let unforked = tabs.filter { !sessions.hasShell(paneID: $0.id) }
        if !unforked.isEmpty {
            await prepareShells(in: model)
            for tab in unforked { fork(tab, in: model) }
        }
        await sessions.activity.readNow(panes: tabs.map(\.id))
    }

    /// A new tab for the script, titled after it and carrying its id so the next pick finds it.
    private func open(
        _ script: RunScript, command: String, in model: WorkspaceModel, bringForward: Bool
    ) async {
        let tab = CenterTabStore.shared.add(
            kind: .terminal, workspaceID: model.workspace.id, title: script.name,
            runScriptID: script.id
        )
        // Queued rather than sent: the shell is forked with the port this script is about to bind
        // already settled. See `TerminalSessionStore.run(_:inPaneID:)`.
        sessions.run(command, inPaneID: tab.id)

        if bringForward {
            WorkspaceTabsStore.shared.select(.tool(tab.id), in: model)
        } else {
            // Nobody is going to draw a tab that was not brought forward, and a shell is forked
            // when its pane is drawn, so a background start forks it here instead.
            await prepareShells(in: model)
            fork(tab, in: model)
        }
    }

    /// What `ToolPaneView` does before it draws a shell: a store for the environment, and the port.
    private func prepareShells(in model: WorkspaceModel) async {
        sessions.useStore(model.store)
        await model.ensurePort()
    }

    private func fork(_ tab: CenterTab, in model: WorkspaceModel) {
        _ = sessions.terminal(
            for: TerminalTab(id: TerminalTabID(tab.id), workspaceID: model.workspace.id, title: tab.title),
            workspace: model.workspace,
            repo: model.repo,
            port: model.port,
            directory: tab.directory
        )
    }

    /// `reveal` rather than `select`, because the tab may have been put into a pane of another tab
    /// since, and only `reveal` finds it there.
    private func reveal(_ tab: CenterTab, in model: WorkspaceModel) {
        WorkspaceTabsStore.shared.reveal(.tool(tab.id), in: model, focusing: true)
    }

    // MARK: - Autostart

    /// Settles autostart for a workspace that has just been shown, or whose setup has just
    /// finished, or whose settings file has just changed. Once per workspace for each set of
    /// autostart commands, per launch.
    ///
    /// Nothing starts without the owner's approval of the exact commands; see
    /// `RunScriptAutostartApproval` for why a line in a committed file is a request and not a
    /// permission. A workspace whose setup script is still to run or running is left unsettled,
    /// and the setup run finishing asks again.
    func considerAutostart(in model: WorkspaceModel) async {
        let workspaceID = model.workspace.id
        guard !settling.contains(workspaceID) else {
            resettle.insert(workspaceID)
            return
        }
        settling.insert(workspaceID)
        defer { settling.remove(workspaceID) }
        repeat {
            resettle.remove(workspaceID)
            await settleAutostart(in: model)
        } while resettle.contains(workspaceID)
    }

    private func settleAutostart(in model: WorkspaceModel) async {
        let workspaceID = model.workspace.id
        guard let repo = model.repo, let store = model.store else { return }

        await model.reloadSettings()
        let settings = model.settings
        let signature = RunScriptAutostart.signature(of: settings.runScripts)
        guard settled[workspaceID] != signature else { return }
        // A question standing about a set that has since changed is about commands that are no
        // longer in the file, so it goes, and the new set is asked about below if it needs to be.
        asks[workspaceID] = nil
        guard RunScriptAutostart.isTimely(
            isRunningSetup: model.isRunningSetup,
            setupState: model.workspace.setupState,
            hasSetupScript: settings.setupScript != nil
        ) else { return }

        let approval = await RunScriptAutostartApproval.load(repoID: repo.id, from: store)
        let decision = RunScriptAutostart.decide(scripts: settings.runScripts, approval: approval)
        switch decision {
        case .nothing:
            settled[workspaceID] = signature
        case .run(let scripts):
            settled[workspaceID] = signature
            await autostart(scripts, in: model)
        case .ask:
            guard !snoozed.contains(repo.id) else { return }
            guard let notice = RunScriptAutostartNotice.make(project: repo.name, decision: decision)
            else { return }
            asks[workspaceID] = (repo.id, notice)
        }
    }

    /// Not Now: this project is not asked again until the next launch.
    func notNow(in model: WorkspaceModel) {
        guard let repoID = model.repo?.id else { return }
        snoozed.insert(repoID)
        dropAsks(of: repoID)
    }

    /// Allow: the exact commands the notice showed are approved for the project, and they start.
    ///
    /// The scripts are the ones the notice was made from rather than the file read again, so what
    /// is approved is exactly what the owner read. A file changed in between asks again on the next
    /// open, which is the approval doing its job.
    func allow(_ notice: RunScriptAutostartNotice, in model: WorkspaceModel) async {
        guard let repo = model.repo, let store = model.store else { return }
        let workspaceID = model.workspace.id
        dropAsks(of: repo.id)
        settled[workspaceID] = RunScriptAutostart.signature(of: notice.scripts)

        let approval = await RunScriptAutostartApproval.load(repoID: repo.id, from: store)
            ?? RunScriptAutostartApproval()
        do {
            try await approval.approving(notice.scripts).save(repoID: repo.id, to: store)
        } catch {
            // Nothing runs on an approval that was not written down: the next launch would ask
            // again about commands that are already running, and the answer would look ignored.
            Log.runScripts.error(
                "Could not save the run script approval for \(repo.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        await autostart(notice.scripts, in: model)
    }

    /// Starts, in the background, the scripts among these whose exact command has not been
    /// autostarted in this workspace yet this launch. See `autostarted`.
    private func autostart(_ scripts: [RunScript], in model: WorkspaceModel) async {
        let workspaceID = model.workspace.id
        for script in scripts {
            let entry = RunScriptAutostart.entry(of: script)
            guard autostarted[workspaceID, default: []].insert(entry).inserted else { continue }
            await start(script, in: model, bringForward: false)
        }
    }

    /// A question is about a project, so answering it in one workspace answers it in every other
    /// workspace of that project that was waiting with the same one.
    private func dropAsks(of repoID: RepoID) {
        for (id, ask) in asks where ask.project == repoID { asks[id] = nil }
    }

    // MARK: - Settings issues

    func dismissIssues(_ notice: SettingsIssuesNotice) {
        dismissedIssues.insert(notice.signature)
    }
}
