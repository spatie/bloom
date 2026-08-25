import AppKit
import Observation
import BloomCore

struct BloomAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The root of the app's state. Owns the store, the repo and workspace lists, and one
/// `WorkspaceModel` per workspace the user has opened.
///
/// Everything here is main-actor isolated. `Store` is an actor, so every read is an await, and
/// the pattern throughout is: mutate through the store, then reload the affected slice.
///
/// **This file is the only writer of `repos` and `workspaces`.** That is the rule the split
/// around it is built on. Seven extensions hold the subjects that used to be stacked in here, and
/// each one changes those lists through a seam that takes an id and says one thing:
/// `hideFromSidebar`, `stopHidingFromSidebar`, `forgetWorkspace`, `invalidateArchived`,
/// `reorderWorkspaces` and `reorderProjects` are all here for that reason, next to the properties
/// whose doc comments rest on having one writer.
///
/// What else stays is what nothing can hold anywhere else: the stored properties, because Swift
/// has none in an extension, `bootstrap` and `shutdownEverything`, the agent allowances and the
/// background refresh loop, the running and waiting mirrors, and the small accessors every
/// extension reads through.
///
/// The subjects that left, and where to look:
///
/// - `AppModel+Archive.swift`, archiving, undoing it, reading the archive and restoring
/// - `AppModel+Workspaces.swift`, creating one, starting one, continuing after a merge
/// - `AppModel+Projects.swift`, adding and removing a project
/// - `AppModel+WorkspaceBridge.swift`, the tools an agent calls back in with
/// - `AppModel+WorkspaceEdits.swift`, a name, a pin, a colour, an unread mark
/// - `AppModel+Navigation.swift`, moving between workspaces and finding one
/// - `AppModel+Naming.swift`, `AppModel+ProjectIcons.swift`, `AppModel+TranscriptSearch.swift`
///
/// The running, waiting and subagent mirrors did NOT leave, and that is deliberate: they would
/// publish the five properties whose comments rest entirely on having one writer. What DID leave
/// is the rule they hold, which is `AgentTurns` in the core, where it can be tested; the
/// mirrors here are what that rule is written into.
@MainActor
@Observable
final class AppModel {
    private(set) var store: Store?
    private(set) var manager: WorkspaceManager?
    /// The workspace bridge: one unix socket for this instance, and the token table an agent's MCP
    /// shim is checked against.
    ///
    /// Outside observation, because nothing draws from it. Nil when the socket could not be bound,
    /// which leaves every chat exactly as it was before the bridge existed rather than refusing to
    /// start one.
    @ObservationIgnored private(set) var bridge: BridgeServer?

    private(set) var repos: [Repo] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var isLoaded = false
    /// What every provider has said about its own allowances, as last read from the store.
    ///
    /// The raw rows rather than a built `QuotaBoard`, because a board is a snapshot taken at an
    /// instant: it drops the windows that have turned over and every countdown in it is measured
    /// from one clock reading. The menu is built at the moment it opens, so it takes that reading
    /// itself and this stays the durable half.
    private(set) var quotas: [AgentQuota] = []

    /// Selecting a workspace is the moment its live model should come into existence, rather than
    /// the moment some view body happens to ask for it. Doing it here keeps model creation out of
    /// the render pass entirely.
    var selection: SidebarSelection {
        get { storedSelection }
        set {
            if let id = newValue.workspaceID, id != storedSelection.workspaceID {
                SwitchTrace.begin(workspaceID: id)
            }
            let vacated = storedSelection.workspaceID
            storedSelection = newValue
            Self.rememberSelection(newValue)
            // Opening or closing a subagent's pane changes which rows are exempt from being
            // removed. See `SubagentRetention`: the row you are reading stays. Both workspaces,
            // because moving away from one leaves a row there that is no longer being read.
            for id in Set([vacated, newValue.workspaceID].compactMap { $0 }) {
                noteSubagentsChanged(workspaceID: id)
            }
            SwitchTrace.mark("selection.set")
            // A switch is the moment to re-read the repository's settings. The Workspace menu
            // lists this repository's run scripts, and somebody who has just added one expects to
            // find it there. The read itself is off the main actor and nothing waits for it, so it
            // is not on the switch's critical path. See `WorkspaceModel.refreshSettings`.
            if let id = newValue.workspaceID { workspaceModels[id]?.refreshSettings() }
            guard let id = newValue.workspaceID, workspaceModels[id] == nil,
                  let workspace = workspaces.first(where: { $0.id == id }) else {
                SwitchTrace.mark("model.reused")
                return
            }
            _ = model(for: workspace)
            SwitchTrace.mark("model.created")
            // An archived selection is not prepared here. Its workspace is not in `workspaces` by
            // definition, so the value has to come from the caller: see `openArchived`.
        }
    }

    private var storedSelection: SidebarSelection = .home

    // MARK: - Remembering where you were

    private static let lastWorkspaceKey = "sidebar.lastWorkspaceID"

    /// Only a workspace is worth remembering. Home and Search are where you go when you are
    /// looking for something, so reopening on them would be reopening on a question rather than
    /// on the work.
    private static func rememberSelection(_ selection: SidebarSelection) {
        guard let id = selection.workspaceID else { return }
        // `rawValue`, not the id itself. User defaults takes an `Any` and only checks at runtime,
        // so handing it a `WorkspaceID` compiles and then raises inside `NSUserDefaults`, which
        // AppKit turns into a trap during the layout pass. Every sidebar click reaches this line,
        // so the app died on selecting any workspace at all.
        UserDefaults.standard.set(id.rawValue, forKey: lastWorkspaceKey)
    }

    /// Reselects the workspace this window was last on.
    ///
    /// Validated against the loaded list rather than trusted: the workspace may have been archived
    /// since, either from here or by someone deleting the worktree, and selecting an id that no
    /// longer exists would leave the window on an empty detail column with a sidebar that agrees
    /// with nothing.
    private func restoreLastSelection() {
        guard case .home = storedSelection else { return }
        guard let id = UserDefaults.standard.string(forKey: Self.lastWorkspaceKey).map(WorkspaceID.init),
              workspaces.contains(where: { $0.id == id }) else { return }
        selection = .workspace(id)
    }

    /// Window chrome, not per-workspace state.
    ///
    /// This used to live on `WorkspaceModel`, which meant the only way to bind it was a
    /// `Binding(get:set:)` reading through an optional selected model. That binding's value
    /// flipped as the selection resolved, and `.inspector(isPresented:)` reacting to it mid layout
    /// put the window into an unbounded Update Constraints loop that AppKit eventually turned into
    /// a crash. Owning it here makes it a plain bindable value. It also matches how a Mac app
    /// behaves: an inspector is shown or hidden for the window, not remembered per document.
    /// It defaults to on and can be started off by `FrameProbe`, which is how a resize measurement
    /// tells the centre column's cost apart from the inspector's.
    var isInspectorVisible = FrameProbe.wantsInspector

    var alert: BloomAlert?
    /// The corner notice. See `BloomNotice`. Set from anywhere, drawn once by `RootView`.
    ///
    /// One slot, so a second notice takes the first one's place and the clock starts again. Not a
    /// queue on purpose: these arrive seconds apart at worst, and a queue would hold a fact about
    /// what is happening now behind a sentence about something that already finished. The banner
    /// keys its countdown on the notice's id, so the replacement gets its own full reading time
    /// rather than whatever was left of its predecessor's.
    var notice: BloomNotice?
    /// Non-nil while an archive is waiting for the user to confirm that the work it would destroy
    /// really is expendable. RootView presents the confirmation from this.
    var pendingArchive: ArchiveRequest?
    var searchQuery = ""
    /// The transcript half of the search screen, one row per workspace. Held here rather than in
    /// `SearchView` for the same reason `searchQuery` is: the screen is destroyed and rebuilt
    /// every time the selection leaves it, and a result list that had to be fetched again on the
    /// way back would flash empty.
    var transcriptResults: [TranscriptWorkspaceMatches] = []
    /// True while there is transcript history the index has not reached yet, so the search screen
    /// can say that the answer is still filling in rather than quietly showing half of it.
    var isTranscriptIndexIncomplete = false
    /// Set by a transcript result on its way to a workspace, read once by the transcript that
    /// arrives there. See `AppModel+TranscriptSearch`.
    var pendingTranscriptTarget: TranscriptSearchTarget?

    /// Both outside observation: nothing draws from a task handle, and a tracked write from a
    /// keystroke handler is a mid-update mutation this file avoids everywhere else.
    @ObservationIgnored var transcriptSearchTask: Task<Void, Never>?
    @ObservationIgnored var transcriptBackfillTask: Task<Void, Never>?
    /// What Home's list is narrowed to.
    ///
    /// Here rather than in `HomeView`'s `@State` for the same reason `searchQuery` is: `HomeView`
    /// is destroyed and rebuilt every time the selection leaves Home and comes back, so a filter
    /// held in the view is silently cleared by opening any workspace at all. A user who narrows
    /// the list to one project, opens something from it and comes back to a list of everything
    /// has been overruled by the app without being told.
    ///
    /// Deliberately not persisted to disk. "Hide archived" is something you turn on to get through
    /// a long list, not a preference, and an app that starts up with a third of the machine's work
    /// missing because of something you did last Tuesday has to be worked out rather than read.
    /// A launch state that hides rows is worse than one that shows them, so this matters more now
    /// that the switch narrows the list rather than widening it.
    var homeFilter = HomeFilter()
    var isCreatingWorkspace = false

    /// The window's undo manager, handed over by the sidebar because only a view can see it.
    ///
    /// Outside observation on purpose: nothing draws from it, and a tracked write from a view
    /// update is exactly the kind of mid-update mutation this file already avoids elsewhere.
    @ObservationIgnored var undoManager: UndoManager?

    /// Live models for workspaces the user has visited this launch. Kept around so switching
    /// back to a workspace does not lose scroll position or a running agent.
    ///
    /// Deliberately outside observation. A view body asks for a model it has not seen before, and
    /// creating one has to be invisible to SwiftUI: a tracked write here would invalidate, from
    /// inside its own body, every view that had just read the dictionary. What the UI actually
    /// watches is the state inside each model, which stays observable.
    /// Internal rather than private because `private` is file scoped and the archive, the
    /// projects and the bridge all live in extensions of their own now. It was already reachable
    /// for reading through `model(for:)`; what widening costs is the write, and the two writers
    /// outside this file both destroy a model whose workspace has genuinely gone.
    @ObservationIgnored var workspaceModels: [WorkspaceID: WorkspaceModel] = [:]

    /// Workspaces whose row has already left the sidebar while their archive is still running.
    ///
    /// The archive hides the row before any filesystem work starts, on purpose, and the store is
    /// not told until the very end. Between those two moments the store still answers "active",
    /// and every full read of it, a reload after a rename, after a pin, after an automatic name
    /// arriving, would put the row back on screen for the rest of the archive. This is how a
    /// reload knows about a decision the store has not caught up with yet. See
    /// `WorkspaceListReconciliation.afterStoreReload`.
    ///
    /// Outside observation deliberately: nothing draws from it, `reload` is the only reader, and
    /// the write that matters to the UI is the one it makes to `workspaces`. It sits up here with
    /// the stored state rather than down beside the archive, because Swift has no stored property
    /// in an extension and the archive is one now.
    @ObservationIgnored private var archivingWorkspaceIDs: Set<WorkspaceID> = []

    /// Workspaces the owner has asked for whose worktree is still being cut.
    ///
    /// The mirror of `archivingWorkspaceIDs` above: that one takes a row away before the disk work
    /// and this one puts one there before the disk work, for the same reason. Pressing Create
    /// dismissed the sheet onto a window where nothing happened until `git worktree add` had
    /// finished. See `PendingWorkspace` for why these are not `Workspace` values and are not in
    /// `workspaces`.
    ///
    /// Observed, unlike the archiving set, and the difference is what each one is for. That one
    /// exists so `reload` can subtract from a list it is about to publish, and the write the
    /// window sees is the write to `workspaces`. This one is drawn: the sidebar reads it directly,
    /// so it has to invalidate when a row is added or taken away.
    ///
    /// Written only by `showPending` and `forgetPending`, and emptied by `reload` the moment the
    /// stored row it is standing in for arrives.
    private(set) var pendingWorkspaces: [PendingWorkspace] = []

    /// Puts a row on screen for a workspace that is about to be cut.
    func showPending(_ pending: PendingWorkspace) {
        guard !pendingWorkspaces.contains(where: { $0.id == pending.id }) else { return }
        pendingWorkspaces.append(pending)
    }

    /// Takes it away again. Only a create that failed calls this: a create that worked has its row
    /// taken by `reload`, in the same update that publishes the stored one, so that there is never
    /// a frame with neither on screen.
    func forgetPending(_ id: WorkspaceID) {
        pendingWorkspaces.removeAll { $0.id == id }
    }

    private var refreshTask: Task<Void, Never>?
    /// When each workspace's diff stat was last asked about, for this launch only. Read by
    /// `DiffRefreshSchedule` to decide which of them this tick is for. Outside observation because
    /// nothing draws from it and it is written every six seconds.
    @ObservationIgnored private var lastDiffRefresh: [WorkspaceID: Date] = [:]
    private var storeObservationTask: Task<Void, Never>?
    private var sessionObservationTask: Task<Void, Never>?
    private var quotaObservationTask: Task<Void, Never>?
    private var quotaPollTask: Task<Void, Never>?
    /// When the one asker last went out, and whether it is still out. Together they are what
    /// makes it one asker: every route into `askForQuotas` reads both, so a background poll, a
    /// menu opening and ten workspaces all collapse into a single question per interval.
    @ObservationIgnored private var lastQuotaAskAt: Date?
    @ObservationIgnored private var isAskingForQuotas = false
    private var identityTask: Task<Void, Never>?
    /// The launch sweep for project icons. Not private, because the work it does is in
    /// `AppModel+ProjectIcons.swift`, and outside observation because nothing draws from it.
    @ObservationIgnored var iconSearchTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// The live model, weakly, for the capture and probe flags only.
    ///
    /// `FrameProbe` runs outside any view, so it has no environment to read this out of, and it
    /// has to be able to open a pane on the selected workspace before it measures one. Weak, and
    /// set here rather than in an initialiser, because `BloomApp` builds this as `@State` and
    /// SwiftUI is free to build more than one of those before it settles on the one it keeps.
    @ObservationIgnored static weak var probeInstance: AppModel?

    /// What `--probe-pane` opens a pane on. Nil outside a probe run and outside a selection.
    @MainActor
    static var probeSelectedModel: WorkspaceModel? { probeInstance?.selectedModel }

    func bootstrap() async {
        Self.probeInstance = self
        guard store == nil else { return }
        do {
            // Off the main actor. Opening the database creates directories, opens the file and
            // runs every migration, and one of those migrations walks the whole messages table.
            // On the main actor that is a beachball on the very first frame.
            let store = try await Task.detached(priority: .userInitiated) {
                try Store(path: try Store.defaultPath())
            }.value
            self.store = store
            self.manager = WorkspaceManager(store: store)
            try await store.resetRunningSessions()
            // The questions those sessions were blocked on. A pending ask whose agent is gone is
            // not a question, it is a row with four live buttons that answer nothing, so they are
            // closed here and the rows that asked them say what happened instead. Bloom denies
            // explicitly on the way out precisely so this stays empty; a crash, a force quit or a
            // power cut all land here.
            let abandoned = try await store.abandonPendingPermissionAsks()
            if abandoned > 0 {
                Log.permissions.info("closed \(abandoned, privacy: .public) questions left by the last launch")
            }
            // Same reasoning as the sessions above, one table over: a setup script is a child of
            // this process, so anything still `running` here died with the last launch and would
            // otherwise spin in the sidebar forever.
            try await store.recoverInterruptedSetups()
            // Before anything can draw a tab strip, because it moves the terminal tabs the bottom
            // panel used to keep in SQLite into the centre column's own list. A workspace whose
            // strip had already been read from user defaults would not show them until the next
            // launch. See `CenterTabStore.adoptTerminalTabs`.
            await CenterTabStore.shared.adoptTerminalTabs(from: store)
            // Touched, not called: reaching the singleton is what runs its init, which is where
            // the centre column's own migration lives. Phase A moves `center.panes.<workspace>` to
            // `center.tab.<content>` and touches neither of the keys `TerminalPaneCensus`
            // enumerates, so on today's data it provably cannot reach the sweep below whatever
            // order they run in. It is here anyway, because the next phase folds the terminal
            // trees in and DOES rewrite a key the census reads, and this line is the slot it
            // has to arrive in. See `WorkspaceTabsStore.init`.
            _ = WorkspaceTabsStore.shared
            // The store every shell's environment is built from, handed over once. It also starts
            // the launch sweep, which kills tmux sessions no tab names any more. It used to be the
            // bottom panel that did this on the first workspace opened; nothing opens now until a
            // terminal tab is drawn, and a launch where none is drawn is exactly the launch whose
            // orphans nobody would collect.
            //
            // AFTER both migrations above, and that order is load bearing rather than tidy: the
            // sweep kills every session no tab names, and until those tabs have moved into the
            // centre column no tab names any of them.
            TerminalSessionStore.shared.useStore(store)
            BottomPanelDefaults.forget()
            bridge = makeBridge(on: store)
            await reload()
            // After `reload`, because the stored id is only trustworthy once there is a list to
            // check it against. Before `isLoaded`, so the window never paints Home first and then
            // jumps to the workspace.
            restoreLastSelection()
            isLoaded = true
            reportFailedDatabaseMigration()
        } catch {
            // `TranscriptStanding.complaint` rather than `readableMessage`: a `SQLiteError`
            // describes itself with the statement that provoked it appended, which is a log's
            // register and not a person's. See its own doc for the modal that made the point.
            alert = BloomAlert(
                title: "Could not open the Bloom database",
                message: TranscriptStanding.complaint(about: error)
            )
            isLoaded = true
        }

        // Held so quitting takes it with us: it is a `gh` subprocess with a ten second timeout,
        // and `Shell.run` terminates the child when its task is cancelled.
        identityTask = Task { await GitHubIdentity.resolve() }
        startBackgroundRefresh()
        startObservingStore()
        startObservingSessions()
        startObservingQuotas()
        startPollingQuotas()
        // Last, and nothing waits for it: the window is already drawn by the time this runs, and
        // every project it has anything to do is one that is drawing its initials meanwhile. See
        // `searchForMissingProjectIcons`.
        startProjectIconSearch()
        // After that one, and for the same reason: this walks every message ever written and the
        // window is already on screen. See `AppModel+TranscriptSearch`.
        startTranscriptIndexBackfill()
    }

    /// The socket an agent's MCP shim forwards to, listening for as long as the app runs.
    ///
    /// Failing to bind it is survivable and is not an alert. Everything the bridge serves is new,
    /// so a chat without one behaves exactly as every chat did last week, and an alert on launch
    /// about a feature nobody has used yet would be noise in front of somebody trying to work.
    /// It is logged, because "the tool is not there" needs somewhere to be findable from.
    /// It hands the server back rather than assigning it, so `bridge` keeps its one writer:
    /// `bootstrap`, in this file, which is the only place that decides what this app is holding.
    /// The building moved to `AppModel+WorkspaceBridge.swift` with the tools it serves.
    func makeBridge(on store: Store) -> BridgeServer? {
        do {
            let server = try BridgeServer(store: store, toolbox: bridgeToolbox()) { message in
                Log.bridge.info("\(message, privacy: .public)")
            }
            try server.start()
            return server
        } catch {
            Log.bridge.error("could not start the workspace bridge: \(error.readableMessage, privacy: .public)")
            return nil
        }
    }

    /// The app is fully usable when the copy out of the old directory fails: it just ran the
    /// whole launch against the database in the old location. Saying so matters anyway, because
    /// the retry happens on every launch and a silent failure is one that never gets fixed.
    private func reportFailedDatabaseMigration() {
        guard let outcome = Store.lastMigration, outcome.result == .keptLegacy else { return }
        alert = BloomAlert(
            title: "Still using the database in the old location",
            message: """
                Bloom could not copy \(LegacyDatabase.legacyPath.path) to its new home, so it \
                opened the original instead. Your work is all there. \
                \(outcome.problem ?? "The copy could not be verified.")
                """
        )
    }

    /// Quitting Bloom has to take everything it started with it. macOS does not kill a process's
    /// children, so without this an agent keeps editing a worktree, a dev server keeps its port and
    /// a login shell keeps running, all reparented to launchd. Worse, the next launch marks those
    /// sessions idle and happily resumes them, which puts two `claude` processes on one session.
    func shutdownEverything() async {
        refreshTask?.cancel()
        refreshTask = nil
        storeObservationTask?.cancel()
        storeObservationTask = nil
        sessionObservationTask?.cancel()
        sessionObservationTask = nil
        quotaObservationTask?.cancel()
        quotaObservationTask = nil
        quotaPollTask?.cancel()
        quotaPollTask = nil
        identityTask?.cancel()
        identityTask = nil
        iconSearchTask?.cancel()
        iconSearchTask = nil
        // Before the agents are signalled, so a turn cannot start a tool call against a socket
        // that is about to stop being answered. Every token dies with the process anyway: they are
        // held in memory precisely so nothing outlives the launch that minted it.
        bridge?.stop()
        bridge = nil

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
            // Both lists are read before either is published, because the `await` between two
            // assignments is a suspension point the sidebar renders in. Publishing the projects
            // first drew every section with its "No workspaces yet" placeholder, and the next
            // update then deleted that placeholder and inserted the real rows in every section at
            // once. That is an insert above existing rows in an `NSTableView`, which makes
            // AppKit's row span cache call back into itself while it recomputes the table height:
            // the "reentrant operation in its NSTableView delegate" warning on every launch.
            // Assigning both at once turns the whole reload into a single row diff.
            let loadedRepos = try await store.repos()
            let loadedWorkspaces = try await store.workspaces()
            // Minus whatever is being archived right now, which the store has not heard about
            // yet: see `archivingWorkspaceIDs`.
            let reconciled = WorkspaceListReconciliation.afterStoreReload(
                fresh: loadedWorkspaces, archiving: archivingWorkspaceIDs
            )
            // Each only when it moved. An identical value assigned back is still a mutation as far
            // as the Observation runtime is concerned, so an unconditional pair of writes here
            // invalidates every view in the window that reads either list. This runs on arriving at
            // a workspace with unread work, after every finished turn and after every write
            // anything makes, and the projects in particular almost never change.
            // `refreshDiffStats` has compared before assigning all along; this is the same rule in
            // the other place that publishes.
            if repos != loadedRepos { repos = loadedRepos }
            if workspaces != reconciled { workspaces = reconciled }
            // The stood-in row goes exactly when the real one arrives, and here rather than at the
            // call site is what makes that true without anybody having to remember an order.
            // `WorkspaceStartRequest` carries the id, so the row the store just answered with IS
            // the pending one, and this write lands in the same update as the assignment above:
            // there is no frame with both on screen and none with neither. A create that never
            // gets this far is `forgetPending`'s, and it is the only caller.
            if !pendingWorkspaces.isEmpty {
                let landed = Set(reconciled.map(\.id))
                pendingWorkspaces.removeAll { landed.contains($0.id) }
            }
            // The models hold a copy of their `Workspace`, and this is where those copies go
            // stale. Refreshing here keeps `model(for:)` out of every view body.
            for workspace in workspaces {
                if let existing = workspaceModels[workspace.id], existing.workspace != workspace {
                    existing.workspace = workspace
                }
            }
        } catch {
            alert = BloomAlert(
                title: "Could not read workspaces",
                message: TranscriptStanding.complaint(about: error)
            )
        }
    }

    /// One project's two icon columns, in memory, after they have been written to the store.
    ///
    /// Here because `repos` is `private(set)` and the sweep that calls this lives in
    /// `AppModel+ProjectIcons.swift`. Named columns rather than a whole `Repo`, for the same
    /// reason `Store.update(repoID:)` exists: the value the sweep is holding was read before a
    /// walk of the project's folder, and anything else about the project may have moved since.
    func adoptProjectIcon(_ path: String?, source: RepoIconSource, forRepoID id: RepoID) {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return }
        repos[index].iconPath = path
        repos[index].iconSource = source
    }

    // MARK: - Agent allowances

    /// Writes what a backend has just reported about its own limits.
    ///
    /// Called from a transcript, which is the only place the event arrives, but the value written
    /// is account wide rather than per workspace: two chats on the same login describe the same
    /// five hour window, and the store keys on provider and window so the two land on one row.
    /// The reload is left to the store's own change feed below rather than done here, so a write
    /// from anywhere reaches the menu the same way.
    func recordQuotas(_ reported: [AgentQuota]) async {
        guard let store, !reported.isEmpty else { return }
        // Merged before it is written, because one of the two providers says in its own schema
        // that what it sends is a sparse delta over the last full snapshot. See `QuotaMerge`.
        let quotas = QuotaMerge.resolved(reported, against: self.quotas)
        do {
            try await store.recordQuotas(quotas)
        } catch {
            // Nothing to say to anybody. A missed allowance reading is a menu that is a few
            // minutes out of date, and the next turn on either backend reports again.
        }
    }

    func reloadQuotas() async {
        guard let store else { return }
        let loaded = (try? await store.quotas()) ?? []
        if quotas != loaded { quotas = loaded }
    }

    /// Asks every provider what is left, rather than waiting to be told.
    ///
    /// **This is the one asker.** Nothing else in the app may call a `AgentQuotaSource`, and this
    /// takes no session, no workspace and no runner, because an allowance is account wide: ten
    /// workspaces open is ten views of one number, and ten askers would be ten HTTP calls for it.
    /// The gap is the shortest acceptable age of the last answer, so a menu opening can ask sooner
    /// than the background poll without being a button that hammers an endpoint.
    ///
    /// Nothing is thrown and nothing is reported. A provider that is not installed or not logged
    /// in answers nothing, which is the same as never having been asked, and the panel keeps
    /// saying what it already knew.
    func refreshQuotas(after gap: TimeInterval = QuotaPollSchedule.interval) async {
        guard !isAskingForQuotas,
              QuotaPollSchedule.isDue(lastAskedAt: lastQuotaAskAt, at: Date(), after: gap)
        else { return }
        isAskingForQuotas = true
        lastQuotaAskAt = Date()
        defer { isAskingForQuotas = false }
        await recordQuotas(await AgentQuotaSources.readAll())
    }

    /// The background poll, which is what keeps the menu bar's own severity honest for somebody
    /// who never opens the menu. `QuotaPollSchedule` holds the interval and the argument for it.
    private func startPollingQuotas() {
        quotaPollTask?.cancel()
        quotaPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshQuotas()
                try? await Task.sleep(for: .seconds(QuotaPollSchedule.interval))
            }
        }
    }

    /// Follows the store, so a write anybody makes is a window that has already redrawn.
    ///
    /// `reload()` used to be called by hand from twenty one places, every one of them a writer
    /// that remembered. This is the same reload driven by the write itself, from `Store`'s update
    /// hook, so a writer that forgets, or one that lives in another part of the process entirely,
    /// still ends up on screen. See `StoreObservation.swift`.
    ///
    /// Four calls are left, and each of them has the same reason: the line after it needs the row
    /// present now rather than a few milliseconds from now. `bootstrap` restores the selection,
    /// `adopt` and `restore` select the workspace they have just produced, and
    /// `undoOptimisticArchive` puts back a row that was only ever removed in memory, so no write
    /// happened and there is nothing for the feed to publish. Anything else that reloads by hand
    /// is doing work this task already does.
    ///
    /// Started at the end of `bootstrap` and not earlier, because the recovery writes above it
    /// (`resetRunningSessions`, `abandonPendingPermissionAsks`, `recoverInterruptedSetups`) are the
    /// app tidying up after its last launch, and the first thing this saw would otherwise be that.
    ///
    /// It subscribes to the two tables `reload` actually reads and to nothing else. `messages` in
    /// particular is deliberately absent: it is the hottest write path in the app for the whole of
    /// a streaming turn, `reload` does not read it, and the transcript has its own precise feed in
    /// the runner's event pump. Bloom has already put out two performance fires, a busy indicator
    /// burning eleven seconds of CPU and a workspace switch that took a second, and this is exactly
    /// how a third would start.
    ///
    /// It reads and it publishes. It must never write to the store: read the two rules on
    /// `StoreChangeHub` before adding anything here.
    private func startObservingStore() {
        guard let store else { return }
        storeObservationTask?.cancel()
        storeObservationTask = Task { [weak self] in
            for await _ in store.changes(of: [.repos, .workspaces]) {
                guard let self else { return }
                await self.reload()
            }
        }
    }

    /// Which chats the store says are mid turn, on a feed of their own.
    ///
    /// Separate from the one above because `reload` reads the projects and the workspaces and
    /// neither of them moves when a turn starts, and because the sessions table is written several
    /// times a turn where the workspace row is written only when its diff stat actually changes.
    /// That difference is the whole reason this feed exists: the sidebar's running mark used to
    /// have no invalidation of its own and was carried by the diff stat refresh reassigning
    /// `workspaces`, so a turn that wrote nothing to the worktree, an agent reading and running
    /// commands, never moved anything the mark was watching. See `AgentTurns`.
    ///
    /// It reads and it publishes, like the feed above. Read the two rules on `StoreChangeHub`
    /// before adding anything here.
    private func startObservingSessions() {
        guard let store else { return }
        sessionObservationTask?.cancel()
        sessionObservationTask = Task { [weak self] in
            await self?.refreshAgentTurns()
            for await _ in store.changes(of: [.sessions]) {
                guard let self else { return }
                await self.refreshAgentTurns()
            }
        }
    }

    /// The allowance rows, on a feed of their own.
    ///
    /// Separate from the one above because `reload` reads neither table and a rate limit event
    /// arriving after every turn on every workspace must not drag a full workspace reload behind
    /// it. `Store.quotas` deletes the rows that have turned over, which is a write on a read and
    /// therefore the one thing `StoreChangeHub` warns about: it is safe because the delete only
    /// happens when there is something stale to delete, so the loop it could start converges after
    /// one extra pass and cannot run on.
    private func startObservingQuotas() {
        guard let store else { return }
        quotaObservationTask?.cancel()
        quotaObservationTask = Task { [weak self] in
            await self?.reloadQuotas()
            for await _ in store.changes(of: [.agentQuotas]) {
                guard let self else { return }
                await self.reloadQuotas()
            }
        }
    }

    /// Refreshes diff stats for every active workspace so the sidebar counts stay honest even
    /// when the user edits files outside Bloom.
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
                await self.refreshSelectedChangedFiles()
            }
        }
    }

    /// Keeps the inspector's list of changed files current while an agent is writing.
    ///
    /// The diff stat above is a per-workspace total held in the store. The list of files is
    /// `WorkspaceModel`'s own and used to be re-read only when the reader did something, so a turn
    /// that ran for two minutes showed a file list from two minutes ago and the only way out was a
    /// Refresh button, which is a chore the app should not be handing anyone.
    ///
    /// Only the selected workspace pays for it. It is the one on screen, and every other one would
    /// be a `git diff` nobody is looking at. The commands are the same read-only plumbing the diff
    /// stat runs, with `GIT_OPTIONAL_LOCKS=0`, so they do not queue behind the index lock an agent
    /// takes while it commits.
    private func refreshSelectedChangedFiles() async {
        guard let id = selection.workspaceID, let model = workspaceModels[id] else { return }
        // A worktree removed outside Bloom would make git walk up to the parent repository and
        // answer about the wrong tree, exactly as above.
        guard FileManager.default.fileExists(atPath: model.workspace.path) else { return }

        await model.refreshChanges(.quiet)
    }

    func refreshDiffStats() async {
        guard let manager else { return }

        // Not every workspace on every tick. `DiffRefreshSchedule` carries the measurement: one
        // pass over one worktree is seven git processes, and running twenty of them every six
        // seconds on an idle machine is what put Bloom under "Using Significant Energy".
        var busy = runningWorkspaceIDs
        if let selected = selection.workspaceID { busy.insert(selected) }
        let due = Set(DiffRefreshSchedule.due(
            workspaces: workspaces.map(\.id),
            busy: busy,
            lastRefreshed: lastDiffRefresh,
            now: Date()
        ))

        // Keyed on what is here now, so a workspace archived while the app was running stops being
        // remembered rather than pinning a path that no longer exists.
        let present = Set(workspaces.map(\.id))
        lastDiffRefresh = lastDiffRefresh.filter { present.contains($0.key) }

        for workspace in workspaces where due.contains(workspace.id) {
            guard !Task.isCancelled else { return }
            // A worktree that has been removed outside Bloom would make git walk up to the parent
            // repository and answer about the wrong tree.
            guard FileManager.default.fileExists(atPath: workspace.path) else { continue }
            await Self.withTimeLimit(.seconds(5)) {
                await manager.refreshDiffStat(workspace: workspace)
            }
            // After the pass rather than before it, so a workspace whose git call took four
            // seconds is not immediately due again on the next tick.
            lastDiffRefresh[workspace.id] = Date()
        }
        // Nothing is read back here. `Store.updateDiffStat` only writes when one of the three
        // numbers has actually moved, and a write that happens publishes itself, so the sidebar is
        // refreshed by the same feed as every other change to a row. On an idle machine this whole
        // pass now writes nothing, publishes nothing and costs the window nothing, where it used
        // to re-read every workspace every six seconds whether or not anything had changed.
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

    // MARK: - Archived workspaces

    /// Every workspace that has been archived, newest first is not promised: this is the store's
    /// own order, and the one screen that shows them sorts by recency itself.
    ///
    /// `workspaces` holds active ones only, so that the sidebar can never offer a worktree that is
    /// no longer on disk. Home is the one screen that has to be able to look past that, and it
    /// asks here rather than reaching around this model into the store, because only this model
    /// knows when the answer changed.
    ///
    /// A failed read is not remembered, so the next caller tries again rather than being told
    /// forever that nothing was ever archived.
    func archivedWorkspaces() async -> [Workspace] {
        if let cachedArchived { return cachedArchived }
        guard let store, let all = try? await store.workspaces(includeArchived: true) else {
            return []
        }
        let archived = all.filter { $0.state != .active }
        cachedArchived = archived
        return archived
    }

    /// Called from the two places that can change what is archived: a completed archive, and a
    /// completed restore. Not from `reload`, which runs for a diff stat refresh several times a
    /// minute and would turn the cache into a per-refresh database read.
    /// Internal rather than private: the archive and the restore both change what is archived
    /// and both live in `AppModel+Archive.swift` now. It is a seam of exactly the shape the
    /// property wants, taking nothing and saying one thing, so `archivedRevision` and
    /// `cachedArchived` keep their single writer, which is this method.
    func invalidateArchived() {
        cachedArchived = nil
        archivedRevision &+= 1
    }

    /// Bumped whenever an archive or a restore changes what is archived.
    ///
    /// The number itself means nothing. It exists so a view can key a load on it and be reloaded
    /// exactly when the answer changed. Home used to key on `workspaces.count`, which is not the
    /// same thing: archive one workspace and restore another and the count is where it started,
    /// while both lists are different.
    private(set) var archivedRevision = 0

    /// The archived list, read once and kept until `invalidateArchived` says otherwise.
    ///
    /// Outside observation on purpose. Nothing reads it directly; `archivedWorkspaces()` is the
    /// only way in, and a tracked write from inside an `await` a view is suspended on is the kind
    /// of mid-update mutation this file avoids everywhere else.
    @ObservationIgnored private var cachedArchived: [Workspace]?

    // MARK: - Clearing out the archive

    func workspaces(in repo: Repo) -> [Workspace] {
        // `SidebarReorder.drawn` rather than a comparator written here: a restated rule dropped
        // the `createdAt` tiebreak once already, and a drag computes its destination against
        // `drawn`, so any daylight between the two lands the drop one row off.
        SidebarReorder.drawn(workspaces.filter { $0.repoID == repo.id })
    }

    var selectedWorkspace: Workspace? {
        guard let id = selection.workspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// The archived workspace being read, if that is what the window is on.
    ///
    /// Read out of its live model rather than out of a list, because the archived list is loaded
    /// asynchronously and `openArchived` is what put the value there in the first place.
    var selectedArchivedWorkspace: Workspace? {
        guard let id = storedSelection.archivedWorkspaceID else { return nil }
        return workspaceModels[id]?.workspace
    }

    /// The workspace a menu item should act on, archived or not.
    ///
    /// Only for the items that still mean something once the worktree is gone, which is Copy
    /// Branch Name and nothing else. Opening an editor or a Finder window on a path that no
    /// longer exists is not one of them.
    var menuWorkspace: Workspace? {
        selectedWorkspace ?? selectedArchivedWorkspace
    }

    /// The live model for a workspace: created if needed, and handed the workspace value to
    /// refresh the one it holds. The row is only pushed into the model when it differs, because
    /// assigning an identical `Workspace` still counts as a mutation to the Observation runtime.
    ///
    /// Both halves are mutations, so this MUST NOT be called from a view body. Doing so crashed the app:
    /// the toolbar reads the selected model several times per update, each read wrote
    /// `existing.workspace`, that invalidated the toolbar from inside its own update, and SwiftUI
    /// recursed through `setNeedsUpdateConstraints` until AppKit threw. Views use `selectedModel`
    /// or `existingModel(for:)`, which only read.
    @discardableResult
    func model(for workspace: Workspace) -> WorkspaceModel {
        if let existing = workspaceModels[workspace.id] {
            if existing.workspace != workspace { existing.workspace = workspace }
            return existing
        }
        let model = WorkspaceModel(workspace: workspace, app: self)
        workspaceModels[workspace.id] = model
        return model
    }

    /// A pure lookup, safe from a view body.
    func existingModel(for id: WorkspaceID) -> WorkspaceModel? {
        workspaceModels[id]
    }

    /// The selected workspace's model, if it has been prepared. Reading this never mutates.
    var selectedModel: WorkspaceModel? {
        guard let id = storedSelection.workspaceID else { return nil }
        return workspaceModels[id]
    }

    // MARK: - Which agents are running

    /// The workspaces whose agent is mid turn, held here as one observable value.
    ///
    /// It is a stored set rather than a walk of `workspaceModels`, and that is the whole point.
    /// `workspaceModels` is `@ObservationIgnored`, so reading it registers no dependency at all:
    /// a count derived by walking it saw whatever models happened to exist the last time the
    /// reader's body ran, and a model created afterwards could never invalidate it. The sidebar's
    /// status bar is the case that made this visible. Its body runs once, before any workspace
    /// has been opened, over an empty dictionary; selecting a workspace then creates a model
    /// through an untracked write, the agent starts, and nothing ever tells the strip to look
    /// again. It read "Idle" for an entire run while the row two inches above it showed the
    /// running glyph, because that row is inside a list that reads `workspaces` and is redrawn by
    /// the diff stat refresh every few seconds. The readers that looked correct were only ever
    /// being carried by a poll.
    ///
    /// Writing it is a tracked mutation, so every reader (the strip, Home's summary line, the
    /// sidebar rows, the menu bar item, the Dock badge and the sleep assertion) is invalidated by
    /// the same thing, at the same moment, and none of them needs a private counter.
    ///
    /// **What it is built from moved.** It was written from `TranscriptModel.setRunning` alone,
    /// which is edge triggered, so one recompute that came out wrong stood for the whole turn and
    /// a chat with no transcript was never counted at all. It is rebuilt whole by
    /// `recomputeAgentTurns`, from the store's own session rows and from what the live
    /// transcripts say, on every write to the sessions table as well as on every edge.
    private(set) var runningWorkspaceIDs: Set<WorkspaceID> = []

    /// What the store last said about every chat that is mid turn or blocked.
    ///
    /// **The half of the answer that survives a missed signal.** The mirrors used to be written
    /// only by `TranscriptModel.setRunning`, which is edge triggered and idempotent: it writes
    /// nothing when the flag has not moved, so a single moment where the recompute came out wrong
    /// stood for the whole turn, and a turn in a chat this launch had never built a transcript for
    /// was never reported at all. The sidebar drew "No changes" over an agent running three Bash
    /// calls, for the length of the turn, and the session row said `running` the whole time.
    ///
    /// Outside observation, because nothing draws it: it is an input to `recomputeAgentTurns`,
    /// which writes the two sets everything actually reads.
    @ObservationIgnored private var storedActivity: [SessionActivity] = []

    /// Re-reads that half. Called on every write to the sessions table, and once at startup, by
    /// `startObservingSessions`.
    func refreshAgentTurns() async {
        guard let store, let rows = try? await store.sessionActivity() else { return }
        storedActivity = rows
        recomputeAgentTurns()
    }

    /// Told by `TranscriptModel` whenever a turn starts or ends, or a question arrives or is
    /// answered. See `setRunning` and `setAwaitingPermission`, which are the one place each of
    /// those flags moves.
    ///
    /// One seam for both, because both sets are recomputed whole: what changed is not worth
    /// naming when the answer is rebuilt from every source either way, and two seams that took an
    /// id invited the caller to believe only that workspace was being reconsidered.
    func noteAgentTurnsChanged() {
        recomputeAgentTurns()
    }

    /// Rebuilds both mirrors from the store's rows and from what the live transcripts say.
    ///
    /// The rule is `AgentTurns`, in the core and tested, and the precedence it holds is the
    /// reason this is not a union: a live transcript decides its own session, because it hears a
    /// turn end before the row is written, and a session with no transcript is decided by its row,
    /// because that is the only thing that knows about a chat nobody has opened.
    ///
    /// Each set is written only when it has actually moved. An identical value assigned back is
    /// still a mutation to the Observation runtime, and this runs on every session write.
    private func recomputeAgentTurns() {
        let live = workspaceModels.values.flatMap { $0.liveTurns }
        let running = AgentTurns.workspaces(.running, stored: storedActivity, live: live)
        let waiting = AgentTurns.workspaces(.awaitingPermission, stored: storedActivity, live: live)
        if runningWorkspaceIDs != running { runningWorkspaceIDs = running }
        if waitingWorkspaceIDs != waiting { waitingWorkspaceIDs = waiting }
    }

    /// Workspaces whose agent has stopped and is waiting on a person.
    ///
    /// A real observable set, rebuilt beside its sibling above and by the same call, for the
    /// reason `runningWorkspaceIDs` is one:
    /// the obvious alternative is to walk `workspaceModels`, and that dictionary is
    /// `@ObservationIgnored`, so a reader that walked it would register a dependency on nothing.
    /// That is precisely how the sidebar strip came to say "Idle" for an hour while agents ran.
    /// The readers that looked right were being carried by the diff stat poll reassigning
    /// `workspaces` every few seconds, and this signal has no such accidental carrier: an agent
    /// blocked on a question writes nothing to the worktree, so nothing would ever invalidate the
    /// mark and it would sit wrong until something unrelated happened to move.
    private(set) var waitingWorkspaceIDs: Set<WorkspaceID> = []

    /// Takes a workspace's row out of the sidebar without forgetting the workspace.
    ///
    /// The seam the archive reaches for instead of writing `workspaces` itself, and it is two
    /// writes that belong together: the row leaves, and `archivingWorkspaceIDs` remembers that it
    /// left, or the next full read of the store would put it straight back. Here rather than in
    /// `AppModel+Archive.swift` because `private` is file scoped, and `workspaces` is a property
    /// this file's header claims to be the only writer of. A seam taking nothing but an id keeps
    /// that claim true.
    func hideFromSidebar(_ id: WorkspaceID) {
        archivingWorkspaceIDs.insert(id)
        workspaces.removeAll { $0.id == id }
    }

    /// Stops filtering a workspace out of a reload, for an archive that did not happen. Before
    /// the reload rather than after it: the reload is what puts the row back, and it can only do
    /// that once this workspace has stopped being filtered out of it.
    func stopHidingFromSidebar(_ id: WorkspaceID) {
        archivingWorkspaceIDs.remove(id)
    }

    /// Drops everything this model still holds about a workspace that has genuinely gone.
    ///
    /// Deliberately not the same call as `hideFromSidebar`. An archive hides the row before a
    /// single byte moves and forgets the rest only if the disk agrees, so those really are two
    /// moments and a single method would have to be called twice with a flag.
    ///
    /// Its own rows go before the recompute, and that order is the whole of it. This workspace has
    /// gone, `ON DELETE CASCADE` has taken its sessions with it, and the rows cached here were
    /// read before any of that: leaving them in would have the recompute report a running agent in
    /// a workspace that no longer exists until the next write to the sessions table.
    func forgetWorkspace(_ id: WorkspaceID) {
        stopHidingFromSidebar(id)
        workspaceModels[id] = nil
        storedActivity.removeAll { $0.workspaceID == id }
        recomputeAgentTurns()
    }

    /// Whether a workspace is blocked on a question, without forcing a `WorkspaceModel` into
    /// existence. Sidebar rows ask this for every visible workspace on every redraw.
    func isAwaitingPermission(_ workspace: Workspace) -> Bool {
        waitingWorkspaceIDs.contains(workspace.id)
    }

    /// The subagent rows under each workspace, for the sidebar to draw.
    ///
    /// An observable mirror written from one place, exactly like `runningWorkspaceIDs` above and
    /// for exactly the same reason: `workspaceModels` is `@ObservationIgnored`, so a sidebar that
    /// walked it to find the rows would register a dependency on nothing and would only redraw
    /// when the diff stat poll happened to reassign `workspaces`. A subagent that finished four
    /// seconds ago would keep breathing until something unrelated moved.
    ///
    /// Keyed by workspace and holding the ACTIVE session's rows only. A workspace with four chats
    /// runs four turns, and drawing all of their children under one workspace row would say that
    /// this turn spawned eleven subagents when it spawned two.
    private(set) var subagentRows: [WorkspaceID: [SubagentRow]] = [:]

    /// How many of the active turn's subagents failed, per workspace, whether or not they still
    /// have a row. What the workspace row carries, and the reason `SubagentRetention.failureLimit`
    /// is safe: three crosses and a count of five never disagree about how bad it was.
    private(set) var subagentFailures: [WorkspaceID: Int] = [:]

    /// The timers that take a finished row off the pane. One per workspace, because one turn's
    /// rows all expire on one clock and a task per row would be a task per tick.
    @ObservationIgnored private var subagentSweeps: [WorkspaceID: Task<Void, Never>] = [:]

    /// Told by `TranscriptModel` whenever its roster moves, and by `WorkspaceModel` whenever the
    /// active session changes underneath it.
    ///
    /// Recomputed from the workspace's model rather than taken from the caller, like its two
    /// siblings, so a background session's roster cannot land under the workspace row while a
    /// different chat is the one on screen.
    func noteSubagentsChanged(workspaceID: WorkspaceID) {
        subagentSweeps.removeValue(forKey: workspaceID)?.cancel()
        guard let roster = workspaceModels[workspaceID]?.activeSubagentRoster else {
            if subagentRows[workspaceID] != nil { subagentRows[workspaceID] = nil }
            if subagentFailures[workspaceID] != nil { subagentFailures[workspaceID] = nil }
            return
        }

        // **What the selection does when its subagent goes.** It falls back to the parent
        // workspace, which is where every other pane in the window was already pointing: see
        // `SidebarSelection.subagent`, which answers `workspaceID` with the parent precisely so
        // that a subagent selection narrows the centre column and nothing else. Retention never
        // removes the row you are reading, so the only moment this can happen is the next turn
        // starting and clearing the roster underneath it, and the alternative was a centre pane
        // reading "that subagent belonged to a turn that has since been replaced".
        if case .subagent(workspaceID, let id) = selection, roster[id] == nil {
            selection = .workspace(workspaceID)
            return
        }

        let now = Date()
        let rows = SubagentRetention.rows(roster, now: now, opened: selection.subagentID)
        // Ticks arrive about once a second per running subagent and most of them change nothing
        // the row says. An unconditional write would invalidate every sidebar row in the window
        // on each one.
        if rows.isEmpty {
            if subagentRows[workspaceID] != nil { subagentRows[workspaceID] = nil }
        } else if subagentRows[workspaceID] != rows {
            subagentRows[workspaceID] = rows
        }

        let failures = SubagentRetention.failureCount(roster)
        if failures == 0 {
            if subagentFailures[workspaceID] != nil { subagentFailures[workspaceID] = nil }
        } else if subagentFailures[workspaceID] != failures {
            subagentFailures[workspaceID] = failures
        }

        // A row leaving is the one change no line announces: the last thing that happens to a
        // successful subagent is the notification that finished it. Without this the tick would
        // sit there until some other subagent ticked, or for ever if it was the last one working.
        guard let next = SubagentRetention.nextChange(roster, now: now, opened: selection.subagentID)
        else { return }
        subagentSweeps[workspaceID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.noteSubagentsChanged(workspaceID: workspaceID)
        }
    }

    /// The rows under one workspace, without forcing a `WorkspaceModel` into existence. Asked by
    /// the sidebar for every visible workspace on every redraw.
    func subagents(of workspaceID: WorkspaceID) -> [SubagentRow] {
        subagentRows[workspaceID] ?? []
    }

    /// How many of this turn's subagents failed. Asked by the workspace row.
    func subagentFailures(of workspaceID: WorkspaceID) -> Int {
        subagentFailures[workspaceID] ?? 0
    }

    /// How many workspaces are waiting on the user, for the sidebar's status bar, the Dock badge
    /// and the menu bar item.
    ///
    /// Through `DockBadge.waitingCount`, which had one caller and it was a test. This read
    /// `waitingWorkspaceIDs.count` directly, and that set is pruned only where somebody remembered
    /// to, while the number drawn beside it is `DockBadge.unreadCount(in: workspaces)`, which
    /// filters through the live list. So the badge and the menu bar could say "1 waiting" about a
    /// workspace neither list shows: a workspace archived while its agent was mid question leaves
    /// the id behind, and nothing here would ever drop it.
    ///
    /// Counting the same list the other half counts is what makes the two agree by construction
    /// rather than by everybody remembering.
    var waitingCount: Int {
        DockBadge.waitingCount(in: workspaces) { waitingWorkspaceIDs.contains($0.id) }
    }

    #if DEBUG
    /// Puts the running set where a capture run needs it. See `View.acceptsCaptureRunningState`.
    ///
    /// Debug builds only. The busy signals are motion, and motion cannot be judged from a still or
    /// from the source, so there has to be a way to put the window into that state without paying
    /// for five real agents. It writes the same set every other reader is watching rather than
    /// adding a second flag beside it, which is the whole point: what is photographed is what a
    /// real turn produces.
    func setRunningWorkspaceIDsForCapture(_ ids: Set<WorkspaceID>) {
        runningWorkspaceIDs = ids
    }
    #endif

    /// Workspaces with an agent currently running, for the sidebar's status bar and Home's
    /// summary line.
    ///
    /// Not the Dock badge, which counts unread finished work instead: see `DockBadge`. Not the
    /// sleep assertion either, which is driven from `runningAgentCount`.
    var runningCount: Int {
        runningWorkspaceIDs.count
    }

    /// Whether a workspace has a running agent, without forcing a `WorkspaceModel` into
    /// existence. Sidebar rows ask this for every visible workspace on every redraw, and
    /// `model(for:)` mutates observable state, so calling that from a view body would schedule
    /// an extra render pass per row.
    func isRunning(_ workspace: Workspace) -> Bool {
        runningWorkspaceIDs.contains(workspace.id)
    }

    /// How many agents are mid turn, for the confirmation shown on quit.
    ///
    /// Counted over the live models rather than the stored sessions, because a session row says
    /// what was true when it was written and this question is about processes running right now.
    var runningAgentCount: Int {
        runningWorkspaceIDs.count
    }

    /// The workspaces those agents are working in, named so the confirmation can say where the
    /// work would be interrupted rather than only how much of it there is.
    ///
    /// The models first, because a workspace that has just been archived is out of `workspaces`
    /// while its agent is still being wound down, and `workspaces` second, because the mirror is
    /// no longer built from the models alone: a chat mid turn in a workspace nobody has opened is
    /// reported by its session row, and there is no model to take a name from. Counted and named
    /// have to agree, or the confirmation says "2 agents are working" over one line.
    var runningAgentWorkspaceNames: [String] {
        runningWorkspaceIDs
            .compactMap { id in
                workspaceModels[id]?.workspace.name ?? workspaces.first { $0.id == id }?.name
            }
            .sorted()
    }

    // MARK: - Workspaces

    // MARK: - Continuing after a merge

    // MARK: - Undoing an archive

    // MARK: - Reading an archived workspace, and bringing it back

    /// Workspaces whose restore is in flight, so the button that started it can say so and cannot
    /// be pressed twice.
    /// Not `private(set)`. `restore` is the only writer and it lives in
    /// `AppModel+Archive.swift`, so this is the one property the split genuinely publishes. Two
    /// seams for an insert and a remove would be more code saying less than the property does.
    var restoring: Set<WorkspaceID> = []

    /// What the sidebar's drag ends in.
    ///
    /// The two numbers are `onMove`'s, which index the rows as they are DRAWN, so `visible` has to
    /// be the very list the drag happened in: filtered, pinned first, and in that order.
    /// `SidebarReorder` is what turns them into the store's own order, and it lives in `BloomCore`
    /// because that translation is worth testing and a view is not where a test can reach it.
    ///
    /// The new order is put on screen before it is written. A drop is the end of a movement the
    /// table has already animated, and waiting for the write and a reload to come back through an
    /// actor before the rows agree with where they were let go puts a frame of the OLD order
    /// between the settle and the answer.
    ///
    /// That assignment is also what makes the background refresh harmless. `refreshDiffStats`
    /// takes its snapshot before its git calls and reconciles against it several seconds later, so
    /// a reorder landing inside that window is a row that changed since the snapshot, and
    /// `WorkspaceListReconciliation` leaves a changed row alone: membership and order come from
    /// the list as it stands, which is this one.
    ///
    /// The write names the two columns it changes, so nothing here can put back a diff stat or an
    /// archive that landed while the drag was happening. See 34b840b.
    ///
    /// It is also one transaction rather than a write per row, which matters now that the store
    /// announces what it has written: a commit per row is an announcement per row, and this
    /// model's own observer would reload the sidebar between two of them and draw a half
    /// reordered list. `Store.reorderWorkspaces` is where that is written down.
    func reorderWorkspaces(in repo: Repo, visible: [Workspace], from: IndexSet, to: Int) async {
        guard let store else { return }
        let changes = SidebarReorder.move(
            visible: visible, all: workspaces(in: repo), from: from, to: to
        )
        guard !changes.isEmpty else { return }

        let byID = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        workspaces = workspaces.map { workspace in
            guard let change = byID[workspace.id] else { return workspace }
            var moved = workspace
            moved.sortOrder = change.sortOrder
            moved.pinned = change.pinned
            return moved
        }

        try? await store.reorderWorkspaces(changes)
    }

    /// What a drag on a project header ends in.
    ///
    /// The projects are a flat list with one number ordering them, so there is none of the
    /// translation a workspace drag needs: no filter hides a project and nothing sorts ahead of
    /// anything. `to` is already an offset into this list, worked out by `SidebarReorder` from the
    /// flattened rows the pane actually draws.
    ///
    /// The new order is put on screen before it is written, for the reason `reorderWorkspaces`
    /// gives: a drop is the end of a movement the table has already animated, and waiting for the
    /// writes and a reload to come back through an actor would put a frame of the old order
    /// between the settle and the answer. The list is re-sorted here rather than moved, because
    /// every project it holds ends up carrying its own index either way.
    ///
    /// The write names the one column it changes, so a reorder cannot put back a name, a colour
    /// or an icon that landed while the drag was happening. See e47a3b7. It is one transaction for
    /// the same reason `reorderWorkspaces` gives: one commit, one announcement, and no moment at
    /// which the observer can reload a half written order.
    func reorderProjects(id: RepoID, to: Int) async {
        guard let store else { return }
        let changes = SidebarReorder.move(projects: repos, id: id, to: to)
        guard !changes.isEmpty else { return }

        let byID = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        repos = repos
            .map { repo in
                guard let change = byID[repo.id] else { return repo }
                var moved = repo
                moved.sortOrder = change.sortOrder
                return moved
            }
            .sorted { $0.sortOrder < $1.sortOrder }

        try? await store.reorderProjects(changes)
    }

}
