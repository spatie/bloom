import AppKit
import SwiftUI
import Observation
import BloomCore

enum SidebarSelection: Hashable {
    case home
    case search
    case workspace(String)
    /// An archived workspace, open for reading.
    ///
    /// Its own case rather than a flag on `workspace`, because an archived workspace is not a
    /// workspace the window can do anything to. Its worktree is gone, so the inspector has no
    /// diff to show, the toolbar has nothing to act on, the composer has nowhere to send a prompt
    /// and every item in the Workspace menu but one points at a directory that is not there.
    /// Keeping it out of `workspaceID` is what makes all of that fall out for free: the inspector
    /// hides itself, the menu items grey, the background refresh skips it and nothing tries to
    /// reopen it on the next launch.
    case archived(String)

    var workspaceID: String? {
        if case .workspace(let id) = self { return id }
        return nil
    }

    var archivedWorkspaceID: String? {
        if case .archived(let id) = self { return id }
        return nil
    }
}

struct BloomAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Something the app did that the user did not ask for and should still know about.
///
/// Not an alert. An alert stops the window and demands a click, which is far too much for "the
/// name moved and the branch did not"; and staying silent about it is the one thing that would
/// leave somebody believing their branch had been renamed when it had not. So: one sentence, in
/// the corner, that goes away by itself.
struct BloomNotice: Identifiable, Equatable {
    let id = UUID()
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
    /// Set when git could not be asked at all, so the report is empty for want of an answer rather
    /// than because there is nothing at stake. Shown alongside the losses, never instead of them.
    var problem: String?
    /// What the app knows about this workspace that git does not. See `ArchiveHazards`.
    var hazards = ArchiveHazards()

    /// Everything this confirmation exists because of, in the words the sheet will use.
    ///
    /// The live reasons come first. An agent mid turn is producing work that is not in git at all
    /// yet, so it is both the most valuable thing at stake and the one the report cannot see.
    var reasons: [String] {
        hazards.liveLosses + report.losses(
            deletingBranch: hazards.isDeletingBranch,
            isPullRequestMerged: hazards.isPullRequestMerged
        )
    }
}

/// What the app knows about a workspace that a git process cannot.
///
/// Deliberately not fields on `WorkspaceSafetyReport`. That type is computed inside BloomCore by
/// running git, and every field on it is something git answered; neither of these is. An agent mid
/// turn is a process this app is holding a handle to, and the pull request's state came from `gh`
/// minutes ago and is cached above the core. Putting them on the report would mean a report that
/// is wrong until whoever built it remembers to correct it, which is the kind of half-filled
/// safety check that decides whether work gets destroyed.
struct ArchiveHazards {
    /// An agent is mid turn in this workspace, right now.
    var isAgentRunning = false
    /// GitHub says this branch's pull request was merged.
    var isPullRequestMerged = false
    /// Whether this archive will delete the branch as well as the worktree.
    var isDeletingBranch = false

    /// The losses that are not git's to report.
    var liveLosses: [String] {
        isAgentRunning
            ? ["the turn an agent is running in this workspace right now, which is not in git yet"]
            : []
    }
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
            if let id = newValue.workspaceID, id != storedSelection.workspaceID {
                SwitchTrace.begin(workspaceID: id)
            }
            storedSelection = newValue
            Self.rememberSelection(newValue)
            SwitchTrace.mark("selection.set")
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
        UserDefaults.standard.set(id, forKey: lastWorkspaceKey)
    }

    /// Reselects the workspace this window was last on.
    ///
    /// Validated against the loaded list rather than trusted: the workspace may have been archived
    /// since, either from here or by someone deleting the worktree, and selecting an id that no
    /// longer exists would leave the window on an empty detail column with a sidebar that agrees
    /// with nothing.
    private func restoreLastSelection() {
        guard case .home = storedSelection else { return }
        guard let id = UserDefaults.standard.string(forKey: Self.lastWorkspaceKey),
              workspaces.contains(where: { $0.id == id }) else { return }
        selection = .workspace(id)
    }

    /// Window chrome, not per-workspace state.
    ///
    /// These used to live on `WorkspaceModel`, which meant the only way to bind them was a
    /// `Binding(get:set:)` reading through an optional selected model. That binding's value
    /// flipped as the selection resolved, and `.inspector(isPresented:)` reacting to it mid layout
    /// put the window into an unbounded Update Constraints loop that AppKit eventually turned into
    /// a crash. Owning them here makes them a plain bindable value. It also matches how a Mac app
    /// behaves: an inspector is shown or hidden for the window, not remembered per document.
    /// Both default to on, and both can be started off by `FrameProbe`, which is how a resize
    /// measurement tells the centre column's cost apart from the inspector's and the terminal's.
    var isInspectorVisible = FrameProbe.wantsInspector
    var isBottomPanelVisible = FrameProbe.wantsBottomPanel

    var alert: BloomAlert?
    /// The corner notice. See `BloomNotice`. Set from anywhere, drawn once by `RootView`.
    var notice: BloomNotice?
    /// Non-nil while an archive is waiting for the user to confirm that the work it would destroy
    /// really is expendable. RootView presents the confirmation from this.
    var pendingArchive: ArchiveRequest?
    var searchQuery = ""
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
    @ObservationIgnored private var workspaceModels: [String: WorkspaceModel] = [:]

    private var refreshTask: Task<Void, Never>?
    private var identityTask: Task<Void, Never>?
    /// The launch sweep for project icons. Not private, because the work it does is in
    /// `AppModel+ProjectIcons.swift`, and outside observation because nothing draws from it.
    @ObservationIgnored var iconSearchTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func bootstrap() async {
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
            await reload()
            // After `reload`, because the stored id is only trustworthy once there is a list to
            // check it against. Before `isLoaded`, so the window never paints Home first and then
            // jumps to the workspace.
            restoreLastSelection()
            isLoaded = true
            reportFailedDatabaseMigration()
        } catch {
            alert = BloomAlert(title: "Could not open the Bloom database", message: error.readableMessage)
            isLoaded = true
        }

        // Held so quitting takes it with us: it is a `gh` subprocess with a ten second timeout,
        // and `Shell.run` terminates the child when its task is cancelled.
        identityTask = Task { await GitHubIdentity.resolve() }
        startBackgroundRefresh()
        // Last, and nothing waits for it: the window is already drawn by the time this runs, and
        // every project it has anything to do is one that is drawing its initials meanwhile. See
        // `searchForMissingProjectIcons`.
        startProjectIconSearch()
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
        identityTask?.cancel()
        identityTask = nil
        iconSearchTask?.cancel()
        iconSearchTask = nil

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
            // The models hold a copy of their `Workspace`, and this is where those copies go
            // stale. Refreshing here keeps `model(for:)` out of every view body.
            for workspace in workspaces {
                if let existing = workspaceModels[workspace.id], existing.workspace != workspace {
                    existing.workspace = workspace
                }
            }
        } catch {
            alert = BloomAlert(title: "Could not read workspaces", message: error.readableMessage)
        }
    }

    /// One project's two icon columns, in memory, after they have been written to the store.
    ///
    /// Here because `repos` is `private(set)` and the sweep that calls this lives in
    /// `AppModel+ProjectIcons.swift`. Named columns rather than a whole `Repo`, for the same
    /// reason `Store.update(repoID:)` exists: the value the sweep is holding was read before a
    /// walk of the project's folder, and anything else about the project may have moved since.
    func adoptProjectIcon(_ path: String?, source: RepoIconSource, forRepoID id: String) {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return }
        repos[index].iconPath = path
        repos[index].iconSource = source
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
        guard let manager, let store else { return }
        let current = workspaces
        for workspace in current {
            guard !Task.isCancelled else { return }
            // A worktree that has been removed outside Bloom would make git walk up to the parent
            // repository and answer about the wrong tree.
            guard FileManager.default.fileExists(atPath: workspace.path) else { continue }
            await Self.withTimeLimit(.seconds(5)) {
                await manager.refreshDiffStat(workspace: workspace)
            }
        }
        if let updated = try? await store.workspaces() {
            // Never assigned straight over the top, because this answer is about the world as the
            // store knew it and the list can have moved on while all of those git calls ran. The
            // case that made it visible: archiving hides the row first and writes to the store
            // last, so a pass landing in between read a workspace that was still active and put
            // the row back on screen for as long as the archive had left to run.
            // `WorkspaceListReconciliation` is the rule, and the reason it is a rule rather than
            // a special case for archiving.
            let reconciled = WorkspaceListReconciliation.reconciled(
                held: workspaces, snapshot: current, fresh: updated
            )
            // Only reassign when something actually changed, to avoid pointless view updates.
            if reconciled != workspaces { workspaces = reconciled }
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

    // MARK: - Archived workspaces

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
    private func invalidateArchived() {
        cachedArchived = nil
        archivedRevision &+= 1
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

    /// The live model for a workspace, created on first use.
    ///
    /// Called straight from view bodies, so it has to be free of observable writes on the hit path.
    /// The row is only pushed into the model when it differs, because assigning an identical
    /// `Workspace` still counts as a mutation to the Observation runtime.
    /// Creates the model if needed and refreshes the workspace value it holds.
    ///
    /// Both are mutations, so this MUST NOT be called from a view body. Doing so crashed the app:
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
    func existingModel(for id: String) -> WorkspaceModel? {
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
    private(set) var runningWorkspaceIDs: Set<String> = []

    /// Told by `TranscriptModel` whenever a turn starts or ends. See `TranscriptModel.setRunning`,
    /// which is the one place that flag moves.
    ///
    /// The answer is recomputed from the workspace's model rather than taken from the caller,
    /// because a workspace can hold several sessions and one of them finishing does not mean the
    /// workspace has stopped working.
    func noteRunningChanged(workspaceID: String) {
        let isRunning = workspaceModels[workspaceID]?.isRunning ?? false
        if isRunning {
            runningWorkspaceIDs.insert(workspaceID)
        } else {
            runningWorkspaceIDs.remove(workspaceID)
        }
    }

    /// Workspaces whose agent has stopped and is waiting on a person.
    ///
    /// A real observable set written from one place, for the reason `runningWorkspaceIDs` is one:
    /// the obvious alternative is to walk `workspaceModels`, and that dictionary is
    /// `@ObservationIgnored`, so a reader that walked it would register a dependency on nothing.
    /// That is precisely how the sidebar strip came to say "Idle" for an hour while agents ran.
    /// The readers that looked right were being carried by the diff stat poll reassigning
    /// `workspaces` every few seconds, and this signal has no such accidental carrier: an agent
    /// blocked on a question writes nothing to the worktree, so nothing would ever invalidate the
    /// mark and it would sit wrong until something unrelated happened to move.
    private(set) var waitingWorkspaceIDs: Set<String> = []

    /// Told by `TranscriptModel` whenever a question arrives or is answered. See
    /// `TranscriptModel.setAwaitingPermission`, which is the one place that flag moves.
    ///
    /// Recomputed from the workspace's model rather than taken from the caller, for the same
    /// reason as above: a workspace can hold several sessions, and one of them being answered does
    /// not mean the workspace has stopped waiting.
    func noteWaitingChanged(workspaceID: String) {
        let isWaiting = workspaceModels[workspaceID]?.isAwaitingPermission ?? false
        if isWaiting {
            waitingWorkspaceIDs.insert(workspaceID)
        } else {
            waitingWorkspaceIDs.remove(workspaceID)
        }
    }

    /// Whether a workspace is blocked on a question, without forcing a `WorkspaceModel` into
    /// existence. Sidebar rows ask this for every visible workspace on every redraw.
    func isAwaitingPermission(_ workspace: Workspace) -> Bool {
        waitingWorkspaceIDs.contains(workspace.id)
    }

    /// How many workspaces are waiting on the user, for the sidebar's status bar, the Dock badge
    /// and the menu bar item.
    var waitingCount: Int {
        waitingWorkspaceIDs.count
    }

    #if DEBUG
    /// Puts the running set where a capture run needs it. See `View.acceptsCaptureRunningState`.
    ///
    /// Debug builds only. The busy signals are motion, and motion cannot be judged from a still or
    /// from the source, so there has to be a way to put the window into that state without paying
    /// for five real agents. It writes the same set every other reader is watching rather than
    /// adding a second flag beside it, which is the whole point: what is photographed is what a
    /// real turn produces.
    func setRunningWorkspaceIDsForCapture(_ ids: Set<String>) {
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
    /// Named from the models rather than from `workspaces`, because a workspace that has just
    /// been archived is out of that list while its agent is still being wound down.
    var runningAgentWorkspaceNames: [String] {
        runningWorkspaceIDs
            .compactMap { workspaceModels[$0]?.workspace.name }
            .sorted()
    }

    // MARK: - Repos

    /// Adds a folder as a project, or offers to make it into one.
    ///
    /// A folder that is not a git repository used to end here, in an alert reading "... is not a
    /// git repository", which is true and useless: it names the problem and offers nothing. Every
    /// route in now asks the same three questions first. A repository is added. A folder that has
    /// no business becoming one, a home directory or somebody's whole projects folder, is refused
    /// with a reason. Anything else is offered `ProjectSetupSheet`.
    ///
    /// - Parameter surface: which window asked, so the offer appears on that one. See
    ///   `ProjectSetupSurface`.
    func addRepository(at path: String, presentedIn surface: ProjectSetupSurface = .main) async {
        guard manager != nil else { return }

        let facts = await RepositoryStarter.inspect(path)
        switch FolderVerdict.of(facts) {
        case .alreadyRepository:
            await addKnownRepository(at: facts.path)

        case .refuse(let refusal):
            alert = BloomAlert(
                title: "Bloom will not make a repository here", message: refusal.sentence
            )

        case .offer:
            await offerToStartRepository(at: facts.path, presentedIn: surface)
        }
    }

    /// The original path, for a folder git already recognises.
    private func addKnownRepository(at path: String) async {
        guard let manager else { return }
        do {
            _ = try await manager.addRepository(at: path)
            await reload()
        } catch {
            alert = BloomAlert(title: "Could not add that folder", message: error.readableMessage)
        }
    }

    /// Walks the folder off the main actor and raises the offer.
    ///
    /// The walk is what the dialog's promises are made of, and a folder with a large
    /// `node_modules` in it takes long enough to count that doing it here would freeze the window
    /// between the file panel closing and the sheet appearing.
    private func offerToStartRepository(at path: String, presentedIn surface: ProjectSetupSurface) async {
        let contents = await Task.detached { RepositoryStarter.scan(path) }.value
        let identityProblem = await RepositoryStarter.identityProblem(at: path)

        ProjectSetup.shared.present(ProjectSetup.Request(
            path: path,
            contents: contents,
            surface: surface,
            identityProblem: identityProblem
        ))
    }

    /// Called by `ProjectSetupSheet` once the folder really is a repository.
    func finishProjectSetup(_ path: String?) async {
        ProjectSetup.shared.dismiss()
        guard let path else { return }
        await addKnownRepository(at: path)
    }

    func removeRepository(_ repo: Repo) async {
        guard let store else { return }
        do {
            try await store.deleteRepo(id: repo.id)
            await reload()
        } catch {
            alert = BloomAlert(title: "Could not remove the project", message: error.readableMessage)
        }
    }

    func toggleCollapsed(_ repo: Repo) async {
        guard let store else { return }
        // Toggled against the stored row rather than against the copy the sidebar was drawn
        // from, so the disclosure cannot also write back a project's name, colour or icon.
        _ = try? await store.update(repoID: repo.id) { $0.collapsed.toggle() }
        await reload()
    }

    func rename(_ repo: Repo, to name: String) async {
        guard let store, !name.isEmpty else { return }
        _ = try? await store.update(repoID: repo.id) { $0.name = name }
        await reload()
    }

    // MARK: - Workspaces

    /// Creates the worktree, selects it, kicks off setup, and sends the first prompt once setup
    /// finishes. The whole flow is one call because that is how it reads to the user.
    @discardableResult
    /// `opensWith` decides the starting layout, not a mode: see `WorkspaceStartMode`. A terminal
    /// workspace skips the session and the opening message, because there is nobody to send one
    /// to, and names its own branch since there is no task to derive one from.
    /// `controls` are the model, effort, permission mode and fast mode chosen in the create sheet's
    /// composer footer, which have to be written onto the session before its first turn runs rather
    /// than left to the app-wide defaults. Nil everywhere else, which keeps those callers exactly
    /// as they were.
    ///
    /// `staged` are attachments written before this worktree existed. They are moved into it here,
    /// between the worktree being cut and the opening turn being handed over, because that is the
    /// only moment at which the destination exists and nothing is reading the prompt yet.
    func createWorkspace(
        in repo: Repo,
        prompt: String,
        baseBranch: String? = nil,
        opensWith: WorkspaceStartMode = .chat,
        branch: String? = nil,
        controls: ComposerControls? = nil,
        staged: StagedAttachments? = nil
    ) async -> Workspace? {
        guard let manager, let store else { return nil }
        isCreatingWorkspace = true
        defer { isCreatingWorkspace = false }

        // What the task says without the files named in it. The prompt carries its attachments as
        // paths in the sentence now, and every reader below this line is naming something after
        // what was asked for: a workspace called `9JVKW4` after the folder a screenshot was copied
        // into would be a name nobody could recognise.
        let spoken = AttachmentDraft.withoutAttachments(
            prompt, paths: staged?.attachments.map(\.path) ?? []
        )

        // The codename the workspace wears until a model answers. Decided before the worktree
        // exists so the row never appears under one name and changes to another in the same
        // breath, and nil whenever nothing is going to be asked, in which case `createWorkspace`
        // falls back to `Git.title` exactly as it always has.
        let placeholder = shouldNameAutomatically(name: nil, prompt: spoken, opensWith: opensWith)
            ? await placeholderName()
            : nil

        do {
            let workspace = try await manager.createWorkspace(
                repo: repo,
                prompt: spoken,
                name: opensWith == .terminal ? branch : placeholder,
                branch: branch,
                baseBranch: baseBranch
            )
            await reload()

            if let placeholder {
                beginAutomaticNaming(
                    workspace: workspace,
                    repo: repo,
                    prompt: spoken,
                    placeholder: placeholder
                )
            }
            selection = .workspace(workspace.id)
            WorkspaceStartMode.record(opensWith, workspaceID: workspace.id)

            let model = model(for: workspace)

            guard opensWith == .chat else {
                // Setup still runs. Only the agent turn is skipped.
                model.startSetupThenSend(prompt: nil, repo: repo)
                return workspace
            }

            let session = try await store.upsert(Session(
                workspaceID: workspace.id,
                title: Git.title(from: spoken, maxLength: 40),
                model: controls?.model ?? AppDefaults.fallbackModel,
                effort: controls?.effort ?? AppDefaults.fallbackEffort,
                // The sheet chooses a backend for the first chat and for no other. Every chat
                // opened afterwards picks its own, and two chats in one worktree can be on
                // different ones.
                agentKind: controls?.agentKind ?? .claudeCode,
                permissionMode: controls?.permissionMode ?? AppDefaults.fallbackPermissionMode
            ))
            // Fast mode has no column, and the marker stops the composer's first-open defaults
            // from overruling any of the four the moment the workspace is opened.
            await controls?.store(sessionID: session.id, in: store)
            await model.reloadSessions()
            model.activeSessionID = session.id

            // The agent gets the sentence as it was written, files and all, because the paths in
            // it are already the paths those files have in the worktree: staging lays a draft out
            // under exactly the layout it will have here, so this is a move and nothing has to be
            // rewritten. What is taken out is anything that failed to arrive, which is a path to
            // nothing and worse than one file fewer.
            var opening = prompt
            if let staged, !staged.attachments.isEmpty {
                let moved = Set(
                    AttachmentFiles
                        .adopt(staged.attachments, from: staged.directory, into: workspace.path)
                        .map(\.path)
                )
                opening = AttachmentDraft
                    .parse(prompt, paths: staged.attachments.map(\.path))
                    .keeping { moved.contains($0) }
            }

            model.startSetupThenSend(prompt: opening, repo: repo)
            return workspace
        } catch {
            alert = BloomAlert(title: "Could not create the workspace", message: error.readableMessage)
            return nil
        }
    }

    // MARK: - Continuing after a merge

    /// What pressing Continue on a merged pull request came to.
    ///
    /// Three cases rather than an optional sentence, because they read differently to the person
    /// standing in front of the strip. A refusal is Bloom declining on purpose and naming the
    /// condition; a failure is git or the network; and the success carries its own line, because
    /// the branch it cut and the base it cut from are the two things worth confirming.
    enum ContinuationOutcome {
        case continued(WorkspaceContinuation)
        case refused(ContinuationRefusal)
        case failed(String)
    }

    /// Carries a merged workspace on to a fresh branch, in place.
    ///
    /// Merging leaves a workspace at a dead end: the branch is finished, the pull request is
    /// closed, and the only move the app offered was to archive it and start again. Starting again
    /// throws away everything that makes a warmed-up workspace worth having, and none of it is in
    /// git: the installed dependencies, the copied `.env`, the dev servers on their ports, and
    /// above all the agent's session, which has read this codebase and been corrected about it for
    /// an hour. Continuing keeps every one of those and changes only the thing that is genuinely
    /// finished, which is the branch.
    ///
    /// In order: decide, cut, tell the app, tell the agent. The decision is
    /// `ContinuationGate.decide` in BloomCore and is the only thing here allowed to say yes; the
    /// git work is `WorkspaceManager.continueOnNewBranch`; and the turn that goes to the agent is
    /// the `continueAfterMerge` prompt, editable in Settings like every other one.
    ///
    /// The session is NOT restarted. That is the point: a new session would know nothing, which is
    /// the outcome archiving already gives for free.
    func continueAfterMerge(
        _ workspace: Workspace, pullRequest: PullRequest
    ) async -> ContinuationOutcome {
        guard let manager else { return .failed("Bloom is still starting up.") }

        let facts: ContinuationFacts
        do {
            facts = try await manager.continuationFacts(
                workspace: workspace,
                // GitHub's own answer, from the strip the button lives in rather than from a
                // fresh lookup. The strip is the reason the button is on screen at all, so
                // asking again would only introduce a way for the two to disagree.
                isPullRequestMerged: pullRequest.isMerged,
                isAgentRunning: isRunning(workspace)
            )
        } catch {
            return .failed(error.readableMessage)
        }

        let branch: String
        switch ContinuationGate.decide(facts) {
        case .cut(let cut): branch = cut
        case .refuse(let refusal): return .refused(refusal)
        }

        let continuation: WorkspaceContinuation
        do {
            continuation = try await manager.continueOnNewBranch(
                workspace: workspace, branch: branch
            )
        } catch {
            return .failed(error.readableMessage)
        }

        await reload()
        await adopt(continuation, pullRequest: pullRequest)
        return .continued(continuation)
    }

    /// Everything the app has to forget or refresh now that the worktree is on another branch.
    private func adopt(_ continuation: WorkspaceContinuation, pullRequest: PullRequest) async {
        let model = model(for: continuation.workspace)

        // The merged pull request belonged to the old branch. Left in place it would keep the
        // strip purple and keep offering the button that has just been pressed, and the sidebar's
        // own cache never clears itself: it ignores a nil answer on purpose, so that a slow
        // network does not make the mark flicker, which means nothing else would ever drop it.
        model.pullRequest = nil
        WorkspacePullRequests.shared.forget(continuation.workspace.id)

        // The diff is measured against the base, and the base just moved under it.
        await model.refreshChanges()

        await tellAgent(about: continuation, pullRequest: pullRequest, in: model)
    }

    /// Sends the `continueAfterMerge` prompt into the session that was already running here.
    ///
    /// Silent when there is no session and none can be made. The branch has already moved by this
    /// point and that is the part that matters; an alert about a missing session would be raising
    /// a dialog over the least important half of what was asked for.
    private func tellAgent(
        about continuation: WorkspaceContinuation,
        pullRequest: PullRequest,
        in model: WorkspaceModel
    ) async {
        let template = PromptOverrides().template(for: .continueAfterMerge)
        let render = continuation.render(template: template, pullRequest: pullRequest.number)

        guard let session = await continuationSession(in: model) else { return }
        // The reader pressed a button and a turn is about to stream: put them in front of it.
        model.activeSessionID = session.id
        await model.transcript(for: session).send(render.text)
    }

    /// The session the continue turn goes to: the one the workspace was already using, or a new
    /// one for a workspace whose agent was never started.
    private func continuationSession(in model: WorkspaceModel) async -> Session? {
        if let session = model.activeSession { return session }
        await model.reloadSessions()
        if let session = model.activeSession { return session }
        return await model.createSession(title: "Continue")
    }

    /// Archives when there is nothing to lose, and asks first when there is.
    ///
    /// Nothing is torn down before the decision: a refused archive used to take the workspace's
    /// shells and dev servers with it anyway, which is a strange thing to happen after being told
    /// the workspace was too valuable to remove.
    ///
    /// Whether an entry point asks even when there is nothing to lose is that entry point's own
    /// business, and `alwaysConfirm` is how it says so. Exactly one caller passes it: the sidebar
    /// row's hover archive button, which appears under the pointer unbidden and is the easiest
    /// way in the app to archive something by accident. The context menu, the Workspace menu, the
    /// keyboard shortcut and the merged pull request strip all leave it alone, because opening a
    /// menu or pressing a shortcut is already saying what you mean, and a confirmation with
    /// nothing to warn about is how a confirmation stops being read.
    ///
    /// It is a flag here rather than a second dialog at the call site, and that is deliberate.
    /// The row used to raise a compact "are you sure" of its own, so a workspace with real work
    /// in it produced two dialogs of different shapes for one decision: a small one that warned
    /// about nothing, then a large one listing what was at stake. One question, asked once, in
    /// one shape.
    ///
    /// A merged pull request needs no new logic and gets none. It already clears the commits
    /// through `isPullRequestMerged`, so what is left to stop an archive is an agent mid turn and
    /// work that exists nowhere but that directory. Neither is weakened for it.
    func archive(
        _ workspace: Workspace, deleteBranch: Bool? = nil, alwaysConfirm: Bool = false
    ) async {
        guard let manager, let repo = repo(for: workspace) else {
            Log.archive.error(
                "asked to archive \(workspace.name, privacy: .public), but the app has no manager or no project for it"
            )
            return
        }

        let hazards = ArchiveHazards(
            isAgentRunning: isRunning(workspace),
            isPullRequestMerged: isPullRequestMerged(workspace),
            // Resolved here rather than left as nil, because the confirmation has to say whether
            // the commits are at stake, and only the repository's settings know that when the
            // caller did not say.
            isDeletingBranch: deleteBranch ?? SettingsLoader.load(repo: repo.path).deleteBranchOnArchive
        )

        let report: WorkspaceSafetyReport
        do {
            report = try await manager.safetyReport(workspace: workspace, repo: repo)
        } catch {
            // Git could not answer, and not knowing what is at stake is not a licence to delete it.
            // The user still gets the choice, with the reason the check failed in front of them.
            pendingArchive = ArchiveRequest(
                workspace: workspace,
                report: WorkspaceSafetyReport(),
                deleteBranch: deleteBranch,
                problem: "Bloom could not check this workspace for unsaved work. \(error.readableMessage)",
                hazards: hazards
            )
            return
        }

        let isSafe = report.isSafeToDiscard(
            deletingBranch: hazards.isDeletingBranch,
            isPullRequestMerged: hazards.isPullRequestMerged
        )

        guard isSafe, !hazards.isAgentRunning, !alwaysConfirm else {
            pendingArchive = ArchiveRequest(
                workspace: workspace, report: report, deleteBranch: deleteBranch, hazards: hazards
            )
            return
        }

        await performArchive(
            workspace,
            repo: repo,
            deleteBranch: deleteBranch,
            force: false,
            report: report,
            hazards: hazards
        )
    }

    /// GitHub's verdict on this workspace's branch, from whichever of the two places has already
    /// asked: the open workspace's own model, or the store every sidebar row reads.
    ///
    /// Never asks itself. A merged pull request only ever makes this check more permissive, so a
    /// missing answer costs a confirmation rather than a workspace, and an archive that waited on
    /// the network before it could decide would be worse than the confirmation it saved.
    private func isPullRequestMerged(_ workspace: Workspace) -> Bool {
        let pullRequest = workspaceModels[workspace.id]?.pullRequest
            ?? WorkspacePullRequests.shared.pullRequest(for: workspace.id)
        return pullRequest?.isMerged ?? false
    }

    /// The user has seen exactly what would be destroyed and asked for it anyway.
    ///
    /// Takes the request as an argument, and that is the whole of the fix for an archive that did
    /// nothing at all. This used to read `pendingArchive` back out of the model, and by the time
    /// it ran there was nothing there to read: the confirmation's own dismissal writes `false`
    /// into the `isPresented` binding, `Binding.isPresent()` turns that into `pendingArchive =
    /// nil`, and the button's action is a `Task` that reaches the main actor about 270ms later,
    /// after the dismissal. The guard then failed and the method returned, silently, every single
    /// time. Pressing "Archive and lose that work" genuinely did nothing.
    ///
    /// So nothing here may depend on state a dismissal can clear. The value the dialog was built
    /// from is the value it acts on.
    func confirmArchive(_ request: ArchiveRequest) async {
        pendingArchive = nil
        guard let repo = repo(for: request.workspace) else {
            Log.archive.error(
                "confirmed the archive of \(request.workspace.name, privacy: .public), but its project is gone"
            )
            return
        }
        // A request that carries a problem has no report at all, only the reason git could not be
        // asked. Passing it on would let an empty report be read as "nothing was at stake".
        await performArchive(
            request.workspace,
            repo: repo,
            deleteBranch: request.deleteBranch,
            force: true,
            report: request.problem == nil ? request.report : nil,
            hazards: request.hazards
        )
    }

    func cancelPendingArchive() {
        pendingArchive = nil
    }

    private func performArchive(
        _ workspace: Workspace,
        repo: Repo,
        deleteBranch: Bool?,
        force: Bool,
        report: WorkspaceSafetyReport?,
        hazards: ArchiveHazards
    ) async {
        guard let manager else {
            Log.archive.error(
                "archiving \(workspace.name, privacy: .public) stopped before it began: no workspace manager"
            )
            return
        }

        // The agents go first: they are the ones writing to the worktree that is about to be
        // removed, and `git worktree remove --force` unlinking files under a running agent is how
        // work gets corrupted rather than merely lost. The shells and dev servers only go once the
        // removal has actually happened, so a failing archive script does not cost the user their
        // terminals for nothing.
        //
        // This does mean an archive that the manager then refuses has already stopped the agent.
        // That trade is deliberate and it is the reason the archive script's failure message says
        // so rather than claiming the workspace is untouched. Moving the teardown after the
        // script would mean the script running while an agent still writes, which is worse.
        workspaceModels[workspace.id]?.teardown()

        // Out of the sidebar now, before a single byte moves.
        //
        // Archiving used to show nothing at all until every last thing had finished: a safety
        // report over the whole worktree, an archive script, `git worktree remove` deleting a
        // `node_modules` file by file, a branch delete, and a reload. On a real project that is
        // seconds of a window that looks broken, and the report above is the reason people press
        // the button twice.
        //
        // None of that work decides anything the user has not already decided. The decision was
        // made before this method was called, so the row can go at once and the disk can catch
        // up. If the disk refuses, the `catch` below reloads from the store, where the row is
        // still active, and it comes back with the reason in front of it.
        let previousSelection = selection
        archivingWorkspaceIDs.insert(workspace.id)
        workspaces.removeAll { $0.id == workspace.id }
        if selection.workspaceID == workspace.id { selection = .home }

        do {
            try await manager.archive(
                workspace: workspace,
                repo: repo,
                deleteBranch: deleteBranch,
                force: force,
                isPullRequestMerged: hazards.isPullRequestMerged
            )
            // The store agrees the workspace is archived now, so nothing needs protecting from a
            // reload any more.
            archivingWorkspaceIDs.remove(workspace.id)
            // The worktree is gone from disk now. Its shells are sitting in a directory that no
            // longer exists and its dev servers are still holding their ports, and nothing else in
            // the app will ever come back for them.
            await TerminalSessionStore.shared.discard(workspaceID: workspace.id)
            workspaceModels[workspace.id] = nil
            // The model is what `noteRunningChanged` reads, so the last word about this workspace
            // has to be said before it goes.
            runningWorkspaceIDs.remove(workspace.id)
            waitingWorkspaceIDs.remove(workspace.id)
            // One more workspace is archived now, so anything holding the old answer is wrong.
            invalidateArchived()
            await reload()
            await offerUndo(of: workspace, repo: repo, report: report)
            Log.archive.info("archived \(workspace.name, privacy: .public)")
        } catch let error as WorkspaceError {
            await undoOptimisticArchive(workspace, restoring: previousSelection)
            switch error {
            case .archiveScriptFailed(let status, let output):
                Log.archive.error(
                    "the archive script for \(workspace.name, privacy: .public) exited \(status), so nothing was removed"
                )
                // Worth its own wording: the manager stops before removing anything, so the user
                // needs to hear that the worktree is still there rather than fear the worst. It
                // does not claim the workspace is untouched, because the agent went first: see
                // the teardown above.
                //
                // Titled without the workspace name. Names here are whole sentences, and a title
                // built from one wraps to three lines of bold text that reads as the warning
                // itself. The name goes in the message, which has room for it.
                alert = BloomAlert(
                    title: "The archive script failed",
                    message: "\u{201C}\(workspace.name)\u{201D} is still here: its worktree and "
                        + "its branch are untouched. Any agent it was running has been stopped.\n\n"
                        + "The script exited with status \(status).\n\n"
                        // The tail is where a script says why it gave up.
                        + String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1_000))
                )
            case .unsafeToArchive(let fresh):
                Log.archive.notice(
                    "\(workspace.name, privacy: .public) changed between the check and the archive, so it is being asked about again"
                )
                // Only reachable when the worktree changed between the check and the archive.
                pendingArchive = ArchiveRequest(
                    workspace: workspace, report: fresh, deleteBranch: deleteBranch, hazards: hazards
                )
            default:
                Log.archive.error(
                    "could not archive \(workspace.name, privacy: .public): \(error.readableMessage, privacy: .public)"
                )
                alert = BloomAlert(title: "Could not archive the workspace", message: error.readableMessage)
            }
        } catch {
            await undoOptimisticArchive(workspace, restoring: previousSelection)
            Log.archive.error(
                "could not archive \(workspace.name, privacy: .public): \(error.readableMessage, privacy: .public)"
            )
            alert = BloomAlert(title: "Could not archive the workspace", message: error.readableMessage)
        }
    }

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
    /// the write that matters to the UI is the one it makes to `workspaces`.
    @ObservationIgnored private var archivingWorkspaceIDs: Set<String> = []

    /// Puts a workspace back in the sidebar after the disk refused to let it go.
    ///
    /// Reloaded from the store rather than reinstated from a copy held in memory. `Workspace.state`
    /// is only written once the removal has actually happened, so a failed archive leaves the row
    /// exactly as it was, and reading it back is the one version that cannot disagree with what
    /// every other part of the app is about to read.
    private func undoOptimisticArchive(_ workspace: Workspace, restoring selection: SidebarSelection) async {
        // Before the reload rather than after it. The reload is the thing that puts the row back,
        // and it can only do that once this workspace has stopped being filtered out of it.
        archivingWorkspaceIDs.remove(workspace.id)
        await reload()
        self.selection = selection
    }

    // MARK: - Undoing an archive

    /// Offers Edit > Undo for an archive that really can be taken back.
    ///
    /// The test is not "was this archive safe". `WorkspaceSafetyReport.isSafeToDiscard` also weighs
    /// the commits, because deleting the branch would strand them, and an archive that keeps the
    /// branch strands nothing: the branch holds the commits and the worktree is a checkout of it.
    /// What decides is `isRestorableFromBranch`, which asks only whether anything lived in that
    /// directory and nowhere else. The other two guards are about the same promise:
    ///
    /// - The branch is checked on disk rather than inferred from `deleteBranch`, which can also be
    ///   decided by the repository's settings file. A deleted branch takes the commits with it.
    /// - An archive script has already wound the workspace down, and Bloom has no idea what it
    ///   did. Rebuilding the checkout would hand back a workspace whose containers, databases and
    ///   ports are gone, which is not the workspace that was archived.
    ///
    /// A missing report means git could not be asked what was at stake, which is never a reason to
    /// claim there was nothing.
    private func offerUndo(
        of workspace: Workspace, repo: Repo, report: WorkspaceSafetyReport?
    ) async {
        guard let manager, undoManager != nil else { return }
        guard let report, report.isRestorableFromBranch else { return }
        guard SettingsLoader.load(repo: repo.path).archiveScript == nil else { return }
        guard await manager.canRestore(workspace: workspace, repo: repo) else { return }
        registerArchiveUndo(workspace, repo: repo)
    }

    private func registerArchiveUndo(_ workspace: Workspace, repo: Repo) {
        guard let undoManager else { return }
        // The handler runs on the main thread, from the Edit menu or Command+Z, so the isolation
        // is real rather than assumed away.
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.beginRestore(of: workspace, repo: repo) }
        }
        // Named for the action being reversed, which is what every other Mac app puts after
        // "Undo". SwiftUI's stock Edit menu draws a fixed "Undo" title and only takes the enabled
        // state from the manager, so this currently shows up in `undoActionName` rather than in
        // the menu. Spelling it out anyway is what makes the menu title correct the moment that
        // group is replaced.
        undoManager.setActionName("Archive Workspace")
    }

    private func beginRestore(of workspace: Workspace, repo: Repo) {
        Task { await restore(workspace) }
    }

    // MARK: - Reading an archived workspace, and bringing it back

    /// Workspaces whose restore is in flight, so the button that started it can say so and cannot
    /// be pressed twice.
    private(set) var restoring: Set<String> = []

    /// Opens an archived workspace for reading.
    ///
    /// Reading and resuming are two different things and this is the first of them. Everything an
    /// archived workspace ever said is still in the database: the transcript, the sessions, what
    /// each turn cost. Only the worktree is gone. Before this there was no way to reach any of it
    /// once the undo had expired, so a workspace archived yesterday took its whole history out of
    /// the app while its branch sat on disk.
    ///
    /// The model is prepared here rather than in the selection setter, because an archived
    /// workspace is not in `workspaces` and the setter has nowhere to look it up.
    func openArchived(_ workspace: Workspace) {
        model(for: workspace)
        selection = .archived(workspace.id)
    }

    /// Opens whatever a workspace id points at, live or archived.
    ///
    /// The one entry point for "show me this workspace" from outside the window: the menu bar
    /// item, the Services item, a deep link and the capture harness all arrive here through
    /// `.bloomOpenWorkspace`. It used to set `.workspace(id)` whatever the id was, and an id that
    /// had since been archived resolved to no workspace at all, so the window quietly fell back
    /// to Home. Now an archived id opens the reader instead of nothing.
    func open(workspaceID id: String) async {
        if workspaces.contains(where: { $0.id == id }) {
            selection = .workspace(id)
            return
        }
        guard let archived = await archivedWorkspaces().first(where: { $0.id == id }) else { return }
        openArchived(archived)
    }

    /// Where this workspace's branch still is. See `RestoreSource`.
    ///
    /// Asks the network, so it is called once by the screen that offers Restore rather than per
    /// redraw, and never from a body.
    func restoreSource(for workspace: Workspace) async -> RestoreSource? {
        guard let manager, let repo = repo(for: workspace) else { return nil }
        return await manager.restoreSource(workspace: workspace, repo: repo)
    }

    /// Rebuilds the worktree and puts the workspace back in the sidebar.
    ///
    /// This is the second of the two things Restore could mean, and the one that can fail: a
    /// branch that is gone from this Mac and from the remote leaves nothing to build from. The
    /// refusal says so and the workspace stays where it is, still readable.
    ///
    /// No redo is registered when this arrives from Edit > Undo. Redo of an archive would delete
    /// a worktree from a menu item, with no safety report in front of it, which is the one thing
    /// this app is careful never to do.
    func restore(_ workspace: Workspace) async {
        guard let manager else { return }
        guard let repo = repo(for: workspace) else {
            alert = BloomAlert(
                title: "Could not bring \(workspace.name) back",
                message: "Its project is no longer in Bloom, so there is no repository to cut a "
                    + "worktree from. Add the project again and try once more."
            )
            return
        }
        guard !restoring.contains(workspace.id) else { return }

        restoring.insert(workspace.id)
        defer { restoring.remove(workspace.id) }

        do {
            let outcome = try await manager.restore(workspace: workspace, repo: repo)
            // The other half of the pair: this workspace has left the archived list.
            invalidateArchived()
            await reload()
            selection = .workspace(outcome.workspace.id)
            Log.archive.info("restored \(workspace.name, privacy: .public)")

            if let from = outcome.relocatedFrom {
                notice = BloomNotice(
                    message: "Something else is at \(from), so the worktree was rebuilt at "
                        + "\(outcome.workspace.path)."
                )
            }
        } catch {
            Log.archive.error(
                "could not restore \(workspace.name, privacy: .public): \(error.readableMessage, privacy: .public)"
            )
            alert = BloomAlert(
                title: "Could not bring \(workspace.name) back",
                message: error.readableMessage
            )
        }
    }

    func rename(_ workspace: Workspace, to name: String) async {
        guard let store, !name.isEmpty else { return }
        _ = try? await store.update(workspaceID: workspace.id) { $0.name = name }
        await reload()
    }

    func togglePinned(_ workspace: Workspace) async {
        guard let store else { return }
        // Toggled against the stored row rather than against the copy this view was handed,
        // so two presses in quick succession cannot both write the same value.
        _ = try? await store.update(workspaceID: workspace.id) { $0.pinned.toggle() }
        await reload()
    }

    /// Clears the mark that says a turn finished while you were not looking.
    ///
    /// The rule, in full, because three things now depend on it: the Dock badge, the menu bar
    /// item and the weight of a project's name in the sidebar.
    ///
    /// `TranscriptModel.notifyFinished` SETS the flag when a turn ends and the workspace is not
    /// the selected one. This clears it when the workspace's transcript comes on screen, from
    /// `WorkspaceModel.onAppear`. The two are exact duals: the flag means "this finished while it
    /// was not in front of you", and it goes the moment it is.
    ///
    /// Two consequences that have each been mistaken for a bug.
    ///
    /// The first is that launching clears it for the restored workspace. `restoreLastSelection`
    /// reopens the window on the workspace it was last on, that workspace's transcript is what
    /// the window paints, and the finished turn is the last thing in it. Confirmed by capture: a
    /// workspace with the flag set that is not the restored one keeps it, the restored one does
    /// not. That is the same rule as any other selection, and the alternative is worse: the badge
    /// would count the workspace whose transcript is filling the window, and the only way to
    /// clear it would be to navigate away and back.
    ///
    /// The second is that the flag includes turns that failed or were cancelled. That is
    /// deliberate. An agent that fell over is still something waiting for a person, and it is the
    /// one most worth being told about; a mark that counted only successes would go quiet exactly
    /// when something went wrong.
    func markRead(_ workspace: Workspace) async {
        guard let store, workspace.unread else { return }
        _ = try? await store.update(workspaceID: workspace.id) { $0.unread = false }
        await reload()
    }

    /// What the sidebar's drag ends in.
    ///
    /// The two numbers are `onMove`'s, which index the rows as they are DRAWN, so `visible` has to
    /// be the very list the drag happened in: filtered, pinned first, and in that order.
    /// `SidebarReorder` is what turns them into the store's own order, and it lives in `BloomCore`
    /// because that translation is worth testing and a view is not where a test can reach it.
    ///
    /// The new order is put on screen before it is written. A drop is the end of a movement the
    /// table has already animated, and waiting for four writes and a reload to come back through
    /// an actor before the rows agree with where they were let go puts a frame of the OLD order
    /// between the settle and the answer.
    ///
    /// That assignment is also what makes the background refresh harmless. `refreshDiffStats`
    /// takes its snapshot before its git calls and reconciles against it several seconds later, so
    /// a reorder landing inside that window is a row that changed since the snapshot, and
    /// `WorkspaceListReconciliation` leaves a changed row alone: membership and order come from
    /// the list as it stands, which is this one.
    ///
    /// Each write names the two columns it changes, so nothing here can put back a diff stat or an
    /// archive that landed while the drag was happening. See 34b840b.
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

        for change in changes {
            _ = try? await store.update(workspaceID: change.id) {
                $0.sortOrder = change.sortOrder
                $0.pinned = change.pinned
            }
        }
        await reload()
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
    /// Each write names the one column it changes, so a reorder cannot put back a name, a colour
    /// or an icon that landed while the drag was happening. See e47a3b7.
    func reorderProjects(id: String, to: Int) async {
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

        for change in changes {
            _ = try? await store.update(repoID: change.id) { $0.sortOrder = change.sortOrder }
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

    /// Asks for a folder and adds it, which is the whole of what every "Add project" control
    /// does. Four views spelled the pair out themselves.
    func addProjectByAsking() async {
        guard let path = await ProjectFolderPicker.choose() else { return }
        await addRepository(at: path)
    }

    // MARK: - Search

    struct SearchHit: Identifiable {
        var id: String { workspace.id }
        var workspace: Workspace
        var repo: Repo?
        var reason: String
        var isArchived = false
    }

    /// The rule lives in `WorkspaceSearch`, in the core, because Home's filter field and the
    /// Shortcuts entity query ask the same question and used to answer it differently.
    ///
    /// Archived workspaces are searched too, and are passed in rather than read, because the
    /// archived list is a database read and this is called from a view on every keystroke. They
    /// come last: a live workspace is nearly always the one being looked for, and an archived hit
    /// that pushed one down the list would be the search answering a question nobody asked.
    ///
    /// Leaving them out was its own bug. Somebody who archives something and then wants it back
    /// types its name into search first, and search said "No Results" about a workspace whose
    /// branch was sitting on disk.
    func search(_ query: String, alsoSearching archived: [Workspace] = []) -> [SearchHit] {
        let needle = WorkspaceSearch.needle(query)
        guard !needle.isEmpty else { return [] }

        func hits(in list: [Workspace], isArchived: Bool) -> [SearchHit] {
            list.compactMap { workspace in
                let repo = repo(for: workspace)
                guard let reason = WorkspaceSearch.match(
                    workspace: workspace, repo: repo, needle: needle
                ) else { return nil }
                return SearchHit(
                    workspace: workspace, repo: repo, reason: reason, isArchived: isArchived
                )
            }
        }

        return hits(in: workspaces, isArchived: false) + hits(in: archived, isArchived: true)
    }
}
