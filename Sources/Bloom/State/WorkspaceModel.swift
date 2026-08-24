import SwiftUI
import Observation
import Synchronization
import BloomCore

/// A git failure carried back across a task boundary. `any Error` is not `Sendable`, and the only
/// part of it the UI shows is the message.
struct GitFailure: Error, Sendable {
    var message: String
}

/// Live state for one workspace: its sessions, its transcript, what git says changed, and the
/// pull request if there is one. Created lazily by `AppModel.model(for:)` and kept for the
/// lifetime of the launch so switching away and back is free.
@MainActor
@Observable
final class WorkspaceModel {
    var workspace: Workspace
    private unowned let app: AppModel

    var sessions: [Session] = []

    /// Whether the store has answered about this workspace's sessions at all, this launch.
    ///
    /// The same distinction `hasReadChanges` keeps below, and here it is not about what a pane is
    /// allowed to say but about what gets deleted. An empty `sessions` means two different things,
    /// "the store was asked and this workspace has none" and "nobody has asked yet", and
    /// `WorkspaceTabsStore.reconcile` destroys every pane pointer no live session answers for. It
    /// ran from the tab strip's `.task` while this model was still on the `Store` actor, read the
    /// empty list as proof, and dissolved any tab holding a chat beside a terminal or a page on
    /// the first visit of every launch. See `TabReconciliation`, which now refuses an answer
    /// nobody has yet, and `TerminalPaneCensus`, where the same trap cost shells.
    private(set) var hasReadSessions = false

    /// Switching tab is the moment a transcript should come into existence, rather than the
    /// moment a view body happens to ask for one. Preparing it here keeps model creation, which
    /// is an observable write, out of the render pass.
    var activeSessionID: SessionID? {
        get { storedActiveSessionID }
        set {
            // Only when it moved, for the reason `reloadSessions` spells out: an identical value
            // written back is still an invalidation, and this one reaches every pane.
            if storedActiveSessionID != newValue { storedActiveSessionID = newValue }
            prepareActiveTranscript()
            // The sidebar draws the active chat's subagents, so switching tab changes which rows
            // belong under this workspace even though no roster moved.
            app.noteSubagentsChanged(workspaceID: workspace.id)
        }
    }

    private var storedActiveSessionID: SessionID?

    /// One transcript per session, built on demand.
    private var transcripts: [SessionID: TranscriptModel] = [:]

    // Inspector.
    /// How much of this workspace's work the Changes tab is showing.
    ///
    /// Read through the getter, which drops a scope this branch can no longer offer. A commit is
    /// not a stable thing to hold on to: an amend, a rebase or a squash rewrites it, and a scope
    /// pointing at a sha that resolves nowhere is a refresh that fails rather than a list that
    /// narrows. Written through `setDiffScope`, because changing it has to send the pane back to
    /// git and a property that quietly starts a subprocess is a property nobody expects.
    private var storedDiffScope: DiffScope = .all

    var diffScope: DiffScope {
        // Only once git has answered. An empty list from a branch that genuinely has no commits
        // of its own is a real answer and correctly drops a stale scope; the same empty list
        // before anything has been asked is not, and would drop the reader's choice on arrival.
        hasReadBranchCommits ? branchCommits.resolve(storedDiffScope) : storedDiffScope
    }

    /// The commits this branch put on top of its base, for the scope menu to offer.
    private(set) var branchCommits = BranchCommitList()
    private(set) var hasReadBranchCommits = false

    /// What the reader last picked in the tab strip, which is not always what is on screen.
    ///
    /// Kept whole rather than clamped to what is currently on offer, because the Checks tab comes
    /// and goes with the pull request under it. See `InspectorTab.resolve`.
    private var chosenInspectorTab: InspectorTab = .changes

    /// The tabs the strip may draw for this workspace, and the one it is showing.
    var availableInspectorTabs: [InspectorTab] { InspectorTab.available(for: pullRequest) }

    var inspectorTab: InspectorTab {
        get { InspectorTab.resolve(chosenInspectorTab, available: availableInspectorTabs) }
        set { chosenInspectorTab = newValue }
    }
    var changedFiles: [ChangedFile] = []
    var selectedFilePath: String?
    var isLoadingChanges = false
    /// Whether git has answered about this worktree at all, this launch.
    ///
    /// Separate from `isLoadingChanges`, and the difference is what a pane with nothing in it is
    /// allowed to say. An empty `changedFiles` means two completely different things: "git looked
    /// and there is nothing" and "nobody has looked yet". The inspector used to tell them apart by
    /// the loading flag, which is raised by the refresh rather than by the arrival, so a workspace
    /// being opened for the first time drew "No changes yet. Nothing in this worktree differs from
    /// main" for as long as it took the refresh to start. That is a claim, it was made before
    /// anything had been read, and on a large worktree it was on screen for most of a second.
    private(set) var hasReadChanges = false
    /// Counts refreshes that landed, whether or not the list moved. `changedFiles` is written
    /// only when it differs, deliberately, so the six second poll cannot rerun the inspector for
    /// nothing; but the diff open on one file needs to hear about the refreshes the list cannot
    /// see. An agent rewording a line one for one leaves the file's counts, and with them the
    /// whole `ChangedFile` value, exactly where they were, and the review bands must still
    /// re-check their anchors against the worktree. Only that re-check reads this, so the tick
    /// invalidates one small view and not the tree.
    private(set) var changesGeneration = 0
    /// Why the last refresh could not answer. Non-nil means `changedFiles` is the last list git was
    /// able to produce, not what the worktree looks like now.
    var changesError: String?
    var pullRequest: PullRequest?
    var isLoadingPullRequest = false
    /// What the last press on the pull request strip left to say, drawn at the top of the
    /// inspector column.
    ///
    /// It lives on the model rather than in the strip because the two are no longer in the same
    /// SwiftUI root, and it is drawn in the column rather than in the strip because the strip is
    /// in the title bar now. A title bar accessory is laid out from a frame set by hand, one row
    /// tall, so a notice added under the strip was drawn into a band with no room for it and cut
    /// off mid sentence. See `TitleBarStrip` and `InspectorView`.
    var pullRequestNotice: PullRequestNotice?
    /// How many times a turn started by Create pull request has ended with no pull request.
    ///
    /// The button cannot itself fail. It succeeds the moment the turn is handed to the agent, and
    /// everything that decides whether a pull request exists happens minutes later and somewhere
    /// else. A run whose shell calls were denied ended with the strip quietly back at "No pull
    /// request yet", no error and no toast, and the only trace of it a hundred rows up the
    /// transcript. Somebody who presses a button is owed the answer to it where they pressed it.
    ///
    /// A count rather than a flag, because two attempts that both come to nothing are two things
    /// to be told and a flag set twice is one. `PullRequestBar` watches it.
    private(set) var pullRequestShortfalls = 0

    /// Whether the turn now in flight was started by that button, so the count above is only ever
    /// bumped for a turn somebody did ask for a pull request in.
    private var isExpectingPullRequest = false
    /// What this worktree is holding that the remote has not got, refreshed alongside the changed
    /// file list. Nil until the first refresh has answered, which is what stops the strip from
    /// claiming a clean branch before it has looked.
    var localWork: LocalWork?

    // Setup.
    var setupOutput: String = ""
    var isRunningSetup = false
    /// Things Bloom did to this workspace that are worth a line in the transcript: a merge, and
    /// whatever follows it.
    ///
    /// In memory and deliberately so. These are notes about what just happened, shown where the
    /// user is already looking, and they are not messages: nothing here is written to the
    /// `messages` table, counted against the context window, or seen by anything that assembles a
    /// prompt. Setup is not in this list because its state is already durable on the workspace
    /// row; `timeline(isRunningSetup:)` derives that one and puts the two together.
    var events: [WorkspaceEvent] = []

    /// One line for a caller that has just done something to this workspace.
    ///
    ///     model.record(.merged(pullRequest: 42, branchDeleted: false, branch: workspace.branch))
    func record(_ event: WorkspaceEvent) {
        events.append(event)
    }

    /// What the transcript draws above its rows: the setup line, derived from the workspace's own
    /// stored state, then everything Bloom has recorded since, in the order it happened.
    func timeline(isRunningSetup running: Bool) -> [WorkspaceEvent] {
        let setup = WorkspaceEvent.setup(
            state: running ? .running : workspace.setupState,
            log: setupOutput,
            durationMS: setupDurationMS,
            status: setupExitStatus
        )
        return [setup].compactMap { $0 } + events
    }

    /// When the run now in flight started, and what the last finished one cost.
    ///
    /// Kept here rather than on the workspace row because it is about this launch's run: a
    /// duration read back out of the database a week later would be answering a question nobody
    /// asked. The transcript shows it on the line that says setup ended, and shows no duration at
    /// all when it does not know one, which is a workspace reopened after the fact.
    var setupStartedAt: Date?
    var setupDurationMS: Int?

    /// What the last setup script this launch watched exited with.
    ///
    /// Beside `setupDurationMS` and for the same reason: it is about this launch's run. A status
    /// read back out of the database a week later would be answering a question nobody asked, and
    /// a workspace reopened after the fact shows a row with no number in it rather than a number
    /// that might be from a run somebody has since re-run.
    var setupExitStatus: Int?

    // Layout.

    /// The workspace's port block, which is a column on the row rather than a fact about this
    /// launch. See `Workspace.port` for why it has to survive a restart.
    var port: Int { workspace.port }
    /// The allocation in flight, so two callers arriving together get one block. See `ensurePort`.
    @ObservationIgnored private var portTask: Task<Int, Never>?

    /// The in-flight refreshes, so a newer one can cancel the one it replaces. Two overlapping
    /// refreshes both claim `isLoadingChanges`, and the slower one finishing last would otherwise
    /// write its stale answer over the fresh one.
    /// Everything an arrival kicks off that the first frame does not wait for. Cancelled by the
    /// next arrival, so a workspace left mid refresh stops rather than finishing into a model
    /// nobody is looking at. See `onAppear`.
    private var arrivalTask: Task<Void, Never>?

    private var changesTask: Task<Result<ChangesAnswer, GitFailure>, Never>?
    private var pullRequestTask: Task<PullRequest?, Never>?
    /// A setup script can run for minutes (`composer install`, `npm ci`). Without a handle,
    /// archiving mid-setup cannot stop it and it outlives the app.
    private var setupTask: Task<Void, Never>?

    init(workspace: Workspace, app: AppModel) {
        self.workspace = workspace
        self.app = app
        self.setupOutput = workspace.setupLog
        refreshSettings()
    }

    /// What this workspace's repository asks for: the setup script, the run scripts, the rest of
    /// `.conductor/settings.toml`.
    ///
    /// Held here rather than read where it is needed because the Workspace menu reads it, and a
    /// `Commands` body is not a view: it cannot await a file, and it cannot carry a task. It is
    /// re-read whenever the workspace is selected, so a run script added in the project settings
    /// window is in the menu the next time the workspace is on screen.
    private(set) var settings = RepoSettings()

    /// Off the main actor, because this parses up to six files and is called on every switch.
    /// Nothing waits for it: the menu shows the previous answer until this one lands, and on the
    /// first launch of a workspace that is an empty one for a few milliseconds.
    func refreshSettings() {
        Task { [weak self] in await self?.reloadSettings() }
    }

    /// The same read, awaited, for the one caller that cannot carry on without the answer.
    ///
    /// `MenuProbe` builds a workspace row's menu synchronously and photographs it, and the setup
    /// item is not in that menu until the settings file has been read. Everything else wants the
    /// call above, which returns immediately and lets the menu show the previous answer until this
    /// one lands.
    func reloadSettings() async {
        guard let path = repo?.path else { return }
        let loaded = await Task.detached(priority: .utility) {
            SettingsLoader.load(repo: path)
        }.value
        guard settings != loaded else { return }
        settings = loaded
    }

    var store: Store? { app.store }
    var repo: Repo? { app.repo(for: workspace) }

    // MARK: - Sessions

    var activeSession: Session? {
        guard let activeSessionID else { return sessions.first }
        return sessions.first { $0.id == activeSessionID } ?? sessions.first
    }

    /// Reads the session list back from the store.
    ///
    /// Every write here is conditional, and that is the point rather than a tidiness. Assigning an
    /// identical value is still a mutation as far as Observation is concerned, so an unconditional
    /// `sessions = fresh` invalidated the tab strip, both panes and the transcript on every single
    /// arrival at a workspace whose sessions had not moved since the last one. That is a second
    /// full layout of the centre column, on the main thread, for a list that is the same list.
    func reloadSessions() async {
        guard let store else { return }
        SwitchTrace.mark("sessions.query.start", workspace: workspace.id)
        let fresh = (try? await store.sessions(workspaceID: workspace.id)) ?? []
        SwitchTrace.mark("sessions.query.done", workspace: workspace.id)
        if sessions != fresh { sessions = fresh }
        // Conditional for the reason every write here is, and raised only once the answer is in
        // hand: the guard above is the store not being there to ask, which is doubt rather than an
        // empty workspace.
        if !hasReadSessions { hasReadSessions = true }
        SwitchTrace.mark("sessions.assigned", workspace: workspace.id)
        if activeSessionID == nil || !sessions.contains(where: { $0.id == activeSessionID }) {
            activeSessionID = sessions.first?.id
        } else {
            // The setter above prepares the transcript for us. This is the other branch, where the
            // active session has not moved and the transcript may still be the one this launch has
            // never built.
            prepareActiveTranscript()
        }
        SwitchTrace.mark("sessions.prepared", workspace: workspace.id)
    }

    /// - Parameter title: what the chat is called. Nil, which is nearly every caller, takes the
    ///   numbered name the strip gives a new tab: `Chat`, then `Chat 2`. A caller passes one only
    ///   when the chat is being opened FOR something and the name says which, as the pull request
    ///   and merge buttons do. See `PaneNaming` for why a chat is never named after its content.
    @discardableResult
    func createSession(title: String? = nil) async -> Session? {
        guard let store else { return nil }
        let session = Session(
            workspaceID: workspace.id,
            title: title ?? PaneNaming.nextTitle(base: PaneNaming.chat, taken: sessions.map(\.title)),
            sortOrder: sessions.count
        )
        guard let stored = try? await store.upsert(session) else { return nil }
        await reloadSessions()
        activeSessionID = stored.id
        return stored
    }

    /// Puts the workspace's conversations in a given order, and writes it back.
    ///
    /// Ids rather than an offset, because the strip the user drags in is not the list this holds: a
    /// chat absorbed into a pane of another tab keeps its place here while having dropped out of
    /// the strip, so an offset read off the strip means nothing here. `TabReorder` is what turns
    /// one into the other, and it is in the core because it is a decision with cases worth testing.
    ///
    /// **Not async, and that is the point.** The list is put on screen here and the write goes off
    /// behind it, so the strip is showing the new order on the frame the drag is let go rather than
    /// after a round trip through an actor. `AppModel.reorderWorkspaces` is the same shape for the
    /// same reason: a drop is the end of a movement the strip has already made, and waiting for
    /// SQLite to come back would put a frame of the old order between the settle and the answer.
    ///
    /// The write names the one column it changes. `AgentRunner` owns the state, the counters and
    /// the agent session id on these rows and has been writing them all the while, so handing back
    /// a whole `Session` the strip was holding would put those columns back to whatever they looked
    /// like when it read them.
    func reorderSessions(to ids: [SessionID]) {
        guard let store else { return }
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered = ids.compactMap { byID[$0] }
        // The whole run or nothing. `TabReorder` hands back a permutation of the list it was given,
        // so a short answer means the caller worked from a stale reading, and writing it would drop
        // every session it had forgotten about out of the strip.
        guard ordered.count == sessions.count else { return }

        for (order, item) in ordered.enumerated() { ordered[order] = item.with { $0.sortOrder = order } }
        sessions = ordered
        Task { try? await store.reorderSessions(ids: ordered.map(\.id)) }
    }

    /// Whether this session's agent is in the middle of a turn.
    ///
    /// The live transcript is the truth wherever one exists, and only existing ones are consulted:
    /// asking for a transcript would build a model for every session the strip drew.
    func isRunning(_ session: Session) -> Bool {
        if let transcript = transcripts[session.id] { return transcript.isRunning }
        return session.state == .running
    }

    func closeSession(_ session: Session) async {
        guard let store else { return }
        transcripts[session.id]?.teardown()
        transcripts[session.id] = nil
        // Closing is one column. The strip's copy of this row can be a whole turn old, and the
        // runner has been writing the state, the counters and the agent session id into it all
        // the while.
        _ = try? await store.update(sessionID: session.id) { $0.archivedAt = Date() }
        // The chat is over, so its bridge token is a token nothing may use again and the config
        // file carrying it is a dead letter. Nothing used to remove either, and the files are one
        // per session rather than one per instance, so they only ever grew.
        app.bridge?.retire(sessionID: session.id)
        await reloadSessions()
    }

    /// The transcript for a session, wired to its own agent runner.
    ///
    /// Both branches are mutations, so this MUST NOT be called from a view body: creating the
    /// model writes an observed dictionary and pushing the session down writes an observed
    /// property, each of which invalidates, from inside its own body, every view that just read
    /// them. Views read `activeTranscript`, which only looks.
    @discardableResult
    func transcript(for session: Session) -> TranscriptModel {
        if let existing = transcripts[session.id] {
            // Assigning an equal value still counts as a mutation to the Observation runtime.
            if existing.session != session { existing.session = session }
            return existing
        }
        let model = TranscriptModel(session: session, workspace: workspace, app: app)
        transcripts[session.id] = model
        Task { await model.load() }
        return model
    }

    /// A pure lookup, safe from a view body. Nil until the active session has been prepared,
    /// which happens on every path that can change which session is active.
    var activeTranscript: TranscriptModel? {
        activeSession.flatMap { transcripts[$0.id] }
    }

    /// The same pure lookup for any session, which is what a pane needs: with the column split,
    /// the conversation on screen is not always the active one.
    func existingTranscript(for sessionID: SessionID) -> TranscriptModel? {
        transcripts[sessionID]
    }

    /// Builds a session's transcript if this launch has not seen it yet. Called from a task, never
    /// from a body, for the reason `transcript(for:)` spells out.
    func prepareTranscript(for sessionID: SessionID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        transcript(for: session)
    }

    private func prepareActiveTranscript() {
        guard let session = activeSession else { return }
        transcript(for: session)
    }

    var isRunning: Bool {
        transcripts.values.contains { $0.isRunning }
    }

    /// The rows for the subagents the ACTIVE chat's turn has spawned.
    ///
    /// A pure lookup over existing transcripts, safe from a view body, and deliberately not a
    /// union over every session: see `AppModel.subagentRows` for why one workspace row must not
    /// draw four chats' children at once.
    var activeSubagentRows: [SubagentRow] {
        guard let transcript = activeTranscript else { return [] }
        return SubagentRow.rows(transcript.subagents)
    }

    /// Whether any session here has an agent stopped and waiting on a person.
    var isAwaitingPermission: Bool {
        transcripts.values.contains { $0.isAwaitingPermission }
    }

    /// Both callers mean the same thing: this workspace, or the whole app, is going away. So the
    /// agents are killed here rather than merely interrupted, and killed first, which is what lets
    /// every SIGTERM escalation run at the same time instead of one after another.
    func stopEverything() {
        for transcript in transcripts.values { transcript.terminateNow() }
        setupTask?.cancel()
        setupTask = nil
        arrivalTask?.cancel()
        arrivalTask = nil
        fileTreeTask?.cancel()
        fileTreeTask = nil
        // Nilled like the three above: a cancelled refresh returns through its
        // `guard changesTask == task` without clearing the handle, and on the one path where
        // the model survives its teardown (a failed archive restoring the row) a handle left
        // behind made the quiet poll stand down until the workspace was next arrived at.
        changesTask?.cancel()
        changesTask = nil
        pullRequestTask?.cancel()
        pullRequestTask = nil
        // A cancelled refresh returns before it clears its own flag, so the spinner would spin
        // for the rest of the launch.
        isLoadingChanges = false
        isLoadingPullRequest = false
        isRunningSetup = false
    }

    /// The workspace itself is going away, so the runners go too. `stopEverything` signals the
    /// agents, and a transcript left holding a live runner would keep its pump for the rest of the
    /// launch.
    func teardown() {
        stopEverything()
        for transcript in transcripts.values { transcript.teardown() }
        transcripts.removeAll()
    }

    /// The quit path: the same teardown, but it waits for the agents to actually be gone rather
    /// than only asking them to leave.
    func shutdown() async {
        setupTask?.cancel()
        setupTask = nil
        // Nilled like the three above: a cancelled refresh returns through its
        // `guard changesTask == task` without clearing the handle, and on the one path where
        // the model survives its teardown (a failed archive restoring the row) a handle left
        // behind made the quiet poll stand down until the workspace was next arrived at.
        changesTask?.cancel()
        changesTask = nil
        pullRequestTask?.cancel()
        pullRequestTask = nil
        for transcript in transcripts.values {
            await transcript.shutdown()
        }
    }

    // MARK: - First run

    /// Owns the setup run so archiving, or quitting, can stop a `composer install` that is only
    /// halfway through. Cancellation reaches the script itself through `StreamingProcess.lines`.
    /// `prompt` is optional because a terminal workspace has no opening message: it still runs
    /// the setup script, it simply has nothing to say to an agent afterwards.
    ///
    /// **The opening prompt joins the queue here, before the script starts, and this method is
    /// awaited so that nothing typed into the composer can get in front of it.** It used to be
    /// held in a local and sent on the far side of the setup run, which put it on a different
    /// route from anything typed while the script was going, and the two raced: the owner opened a
    /// workspace with "list the technologies used", typed "test" a moment later, and got "test"
    /// answered first. See `Delivery` and `TranscriptModel.submit`.
    func startSetupThenSend(prompt: String?, repo: Repo) async {
        await enqueueOpening(prompt)

        setupTask?.cancel()
        setupGeneration += 1
        let generation = setupGeneration
        setupTask = Task { [weak self] in
            await self?.runSetupThenSend(repo: repo)
            // Only clear the handle if it is still this run's. A cancelled setup finishes after
            // the one that replaced it has already been stored, and clearing unconditionally
            // dropped the live handle, which left the new run with nothing able to cancel it.
            guard let self, self.setupGeneration == generation else { return }
            self.setupTask = nil
        }
    }

    /// Which setup run the stored `setupTask` belongs to.
    private var setupGeneration = 0

    /// Puts the workspace's opening prompt at the front of its chat's queue.
    ///
    /// Nil for a terminal workspace, which runs its setup script and has nothing to say to an
    /// agent afterwards. The session is already there: `AppModel.adopt` creates and loads it
    /// before this is reached, which is the whole reason the enqueue can name a chat rather than
    /// wait for one.
    private func enqueueOpening(_ prompt: String?) async {
        guard let prompt, let store, let session = activeSession else { return }
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        _ = try? await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: body))
        // So the pending bubble is on screen from the first frame of the workspace rather than
        // after the first read of the queue, which is what made the opening prompt invisible for
        // the whole of a setup run.
        await transcript(for: session).refreshQueue()
    }

    /// Runs the setup script, streaming into the transcript's setup row, then lets the chat's
    /// queue move.
    func runSetupThenSend(repo: Repo) async {
        guard let manager = app.manager else { return }

        // Off the main actor: this reads and parses up to six files from disk, and it runs at the
        // moment a workspace is created, which is exactly when the window must stay responsive.
        let repoPath = repo.path
        let settings = await Task.detached(priority: .userInitiated) {
            SettingsLoader.load(repo: repoPath)
        }.value

        if settings.setupScript != nil {
            let succeeded = await stream(setupIn: repo, through: manager)

            // Archiving or quitting cancels this task. Starting an agent in a worktree that is on
            // its way out is the one thing that must not happen here.
            guard !Task.isCancelled else { return }

            if !succeeded {
                // The one sentence every route says about a failed setup, rather than a second
                // one written here that would drift from it. It names no tab, which is what makes
                // it survive the tab it used to name. See `SetupFailure`.
                app.alert = BloomAlert(
                    title: "Setup failed for \(workspace.name)",
                    message: SetupFailure.instruction
                )
                NotificationService.shared.setupFailed(workspace: workspace)
                return
            }
        }

        await reloadSessions()
        guard !Task.isCancelled, let session = activeSession else { return }
        // The worktree is built, so whatever was asked for while it was being built may go, oldest
        // first. Nothing is passed in: the opening prompt is already in the queue, and so is
        // anything typed into the composer since. See `enqueueOpening`.
        await transcript(for: session).drain()
    }

    /// The workspace's own port block, allocated once however many callers ask at once.
    ///
    /// Setup, the terminal pane and the browser each used to run their own if-zero-allocate
    /// dance, and two of them are reachable concurrently: opening a browser while a terminal
    /// pane prepared had both see 0, allocate different blocks, and the last write won, so the
    /// browser opened on one block while the shell exported the other's `BLOOM_PORT`. The task
    /// held here is what stops the two of them probing sixty sockets each; the store is what
    /// stops them disagreeing, because `WorkspaceManager.ensurePort` writes through `update` and
    /// keeps whichever number reached the row first.
    ///
    /// The decision itself is in the core now rather than here. It has to read and write the row
    /// to be worth anything after a relaunch, and the set of blocks already spoken for is every
    /// active row rather than the workspaces somebody has opened this launch.
    @discardableResult
    func ensurePort() async -> Int {
        if port != 0 { return port }
        if let inFlight = portTask { return await inFlight.value }
        guard let manager = app.manager else { return 0 }
        let workspace = workspace
        let task = Task { await manager.ensurePort(for: workspace) }
        portTask = task
        let allocated = await task.value
        portTask = nil
        // The row is the record; this keeps the model in step with it without waiting for the
        // next refresh, so the terminal about to be forked reads the number rather than 0.
        if self.workspace.port == 0 { self.workspace.port = allocated }
        return self.workspace.port
    }

    /// One setup run: the state it resets, the output it streams, and what it leaves behind.
    ///
    /// Shared by the run a workspace opens with and by the re-run below, which differ only in what
    /// happens afterwards. It used to be written out twice, once here and once in the panel's
    /// Setup tab, and the two had already drifted: only one of them cleared the exit status, so a
    /// re-run after a failure drew a red cross over a log that was still being written.
    @discardableResult
    private func stream(setupIn repo: Repo, through manager: WorkspaceManager) async -> Bool {
        isRunningSetup = true
        setupStartedAt = .now
        setupDurationMS = nil
        setupExitStatus = nil
        setupOutput = ""
        // A machine with no free block left is not a reason to refuse to run setup. The script
        // simply gets no port to bind, which it can decide for itself what to do about.
        await ensurePort()

        // Setup scripts are chatty: `composer install` and `bun install` together are thousands of
        // lines. Hopping to the main actor once per line, each time appending to a string that
        // keeps growing, is quadratic work on the main queue and it beachballs the whole window.
        // Lines are collected off-actor and flushed a few times a second.
        let buffer = LineBuffer()
        let flusher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                self.appendSetupOutput(buffer.drain())
            }
        }

        let succeeded = await manager.runSetup(
            workspace: workspace, repo: repo, port: port,
            onExit: { [weak self] status in
                Task { @MainActor in self?.setupExitStatus = status }
            }
        ) { line in
            buffer.append(line)
        }

        flusher.cancel()
        appendSetupOutput(buffer.drain())
        isRunningSetup = false
        setupDurationMS = setupStartedAt.map { Int(Date.now.timeIntervalSince($0) * 1000) }
        await refreshSetupState()
        return succeeded
    }

    /// The setup item this workspace's menus should draw, or nil when there should be none.
    ///
    /// The three facts are gathered here and the decision is taken in `SetupRunOffer`, in the
    /// core, because three menus draw this item now and a menu is a place nothing can test.
    ///
    /// A workspace whose project has been removed has no repository to read a settings file from,
    /// so `settings` was never loaded and there is nothing to offer. That is folded into the first
    /// fact rather than given a case of its own: to this menu the two are one answer, which is
    /// that there is no script here to run.
    var setupRunOffer: SetupRunOffer? {
        SetupRunOffer.offer(
            hasSetupScript: repo != nil && settings.setupScript != nil,
            hasRunSetup: hasRunSetup,
            isRunning: isRunningSetup
        )
    }

    /// Whether there is a setup script to run in this worktree at all, which is what the two
    /// controls that offer a re-run are enabled by.
    ///
    /// The same question `setupRunOffer` answers, asked by the one caller that draws no menu item:
    /// the failed setup row's link in the transcript, which is either there or not. Written in
    /// terms of the offer rather than beside it, so a rule added to one cannot go missing from the
    /// other.
    var canRunSetup: Bool {
        setupRunOffer?.isEnabled == true
    }

    /// Whether setup has ever run here, so a control can say "again" only when there was a first
    /// time. It read "Run setup again" on a workspace whose own header said setup had never run.
    ///
    /// `.pending` with something in the log is `Store.recoverInterruptedSetups` filing a run this
    /// app was killed during, which did happen and is the case "again" is written for.
    var hasRunSetup: Bool {
        workspace.setupState != .pending || !setupOutput.isEmpty
    }

    /// Runs the setup script in this worktree again.
    ///
    /// A recovery rather than a first run, which is why it sends no prompt and reloads no
    /// sessions: the script failed, or it was edited, and it is being run once more. A workspace
    /// that has been open for an hour must not be handed its opening message a second time.
    ///
    /// Through the same `setupTask` the first run uses, so archiving or quitting stops a
    /// `composer install` started from here exactly as it stops one started at creation.
    func runSetupAgain() {
        guard canRunSetup, let repo, let manager = app.manager else { return }
        setupTask?.cancel()
        setupGeneration += 1
        let generation = setupGeneration
        setupTask = Task { [weak self] in
            await self?.stream(setupIn: repo, through: manager)
            guard let self, self.setupGeneration == generation else { return }
            self.setupTask = nil
        }
    }

    /// Re-reads what setup ended up as.
    ///
    /// `WorkspaceManager.runSetup` writes the outcome onto the workspace row, and the copy of that
    /// row this model is holding is as old as the run that just finished. Without this the Setup
    /// tab read its state out of a value that still said `pending`, so its header announced "Setup
    /// has not run yet" directly above the output the script had printed a second earlier.
    ///
    /// Kept rather than left to the store's change feed, which does refresh this model's copy of
    /// the row and would get here on its own a moment later. A moment is the whole problem. The
    /// line above this call clears `isRunningSetup`, and the header reads both values: for as long
    /// as one has moved and the other has not, it is the sentence in the paragraph above, back
    /// again. One indexed read at the end of a run that took minutes is the cheaper side of that
    /// trade by a long way.
    ///
    /// The whole row, not the one column. `setupState` is `internal(set)` in BloomCore now, so
    /// there is no assigning it from here at all, and that is the right answer rather than an
    /// obstacle: `WorkspaceManager.runSetup` writes the state and the log together, and a refresh
    /// that took the state without the log would put this model back in the position the bug above
    /// describes, showing one of the two halves of a run that has finished.
    func refreshSetupState() async {
        guard let store, let fresh = try? await store.workspace(id: workspace.id) else { return }
        workspace = fresh
    }

    /// Appends a batch, keeping only the tail. Called from the flusher, never per line.
    func appendSetupOutput(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        setupOutput += lines.joined(separator: "\n") + "\n"
        // The same cap the row is written under, so the transcript and the stored log agree
        // about how much of a long setup survives. See `Workspace.setupLogLimit`.
        if setupOutput.count > Workspace.setupLogLimit {
            setupOutput = String(setupOutput.suffix(Workspace.setupLogLimit))
        }
    }

    // MARK: - Changes

    /// Why a refresh of the changed file list was asked for, which is what decides how loud it is
    /// allowed to be.
    enum ChangesRefresh {
        /// The reader did something that changed the worktree, or the pane has just opened.
        /// Reports progress, and opens the first file when nothing is open.
        case requested
        /// The poll that keeps the list honest while an agent writes. It has to be invisible: a
        /// spinner every six seconds says less than a list one tick out of date, and moving the
        /// selection would reopen a diff the reader had just closed.
        case quiet
    }

    func refreshChanges(_ reason: ChangesRefresh = .requested) async {
        // A refresh already on its way is about to answer about this same worktree, so the poll
        // stands down rather than cancelling work the reader asked for and starting again.
        if reason == .quiet, changesTask != nil { return }

        changesTask?.cancel()
        let path = workspace.path
        let base = workspace.baseBranch
        // Read here rather than inside the task: the failure below names the workspace, because
        // its worktree path is a directory inside Bloom's workspaces root that the reader neither
        // chose nor can act on.
        let name = workspace.name
        let scope = diffScope
        // Only on a refresh somebody asked for, which is an arrival, a finished turn or a press.
        // Those are exactly the moments a commit can have appeared, and the six second poll is
        // already four git calls without adding a `log` for a menu nobody has opened.
        let wantsCommits = reason == .requested

        let task = Task.detached(priority: .userInitiated) { () -> Result<ChangesAnswer, GitFailure> in
            do {
                let files = try await Git.changedFiles(worktree: path, base: base, scope: scope)
                // In the same task as the file list rather than on a cadence of its own. The one
                // extra command is `status --porcelain -z --branch`, which answers uncommitted,
                // untracked and unpushed at once, so the poll that already runs three git calls
                // every six seconds runs four. Nothing stats the worktree on a redraw: the strip
                // reads a value, and the value is only ever written here.
                //
                // Failing to answer it is not a failure of the refresh. The file list is what the
                // reader asked for; a missing local count means the strip says nothing extra,
                // which is the right answer when we do not know.
                let local = try? await Git.localWork(worktree: path)
                // Same forgiveness as the local counts: failing to list the commits costs the
                // menu its rows, not the reader their file list.
                let commits = wantsCommits
                    ? try? await Git.branchCommits(worktree: path, base: base)
                    : nil
                return .success(ChangesAnswer(files: files, local: local, commits: commits))
            } catch {
                // Diagnosed rather than reported, in the register `WorkspaceStartFailure` set. A
                // worktree deleted underneath Bloom used to surface here as "`git rev-parse
                // --verify main^{commit}` exited 128: fatal: not a git repository", which names
                // neither the workspace nor anything the reader can do. See `WorkspaceTrouble`.
                let trouble = await WorkspaceTrouble.readingChanges(
                    error, workspace: name, path: path, baseBranch: base
                )
                return .failure(GitFailure(message: trouble.sentence))
            }
        }
        changesTask = task
        // Only when there is nothing to show. A workspace this launch has already opened still
        // holds the list git gave it last time, and that list is right until git says otherwise:
        // replacing it with a spinner on every arrival is a flash of nothing between one correct
        // answer and the same correct answer. The spinner is for a workspace being opened for the
        // first time, where there genuinely is nothing yet.
        if reason == .requested, changedFiles.isEmpty { isLoadingChanges = true }
        if reason == .requested { SwitchTrace.mark("changes.git.start", workspace: workspace.id) }

        let outcome = await task.value
        if reason == .requested { SwitchTrace.mark("changes.git.done", workspace: workspace.id) }

        // A newer refresh started while this one was in git, or the workspace is going away. Either
        // way this answer is the stale one, and writing it would undo the fresh one.
        guard changesTask == task, !task.isCancelled else { return }
        changesTask = nil
        // Cleared whatever this refresh asked for, because a quiet one can be the last to land
        // after a requested one raised the flag, and then only it can put the flag down again.
        isLoadingChanges = false

        switch outcome {
        case .failure(let failure):
            hasReadChanges = true
            // Git failing says nothing about the worktree. Replacing the list with an empty one
            // would show the user a clean workspace, which is the one answer that is certainly
            // wrong, so the last known list stays and the failure is reported instead.
            changesError = failure.message

        case .success(let answer):
            hasReadChanges = true
            changesGeneration &+= 1
            // Only when it actually moved. `AppModel`'s poll lands here every six seconds, and a
            // write of an identical list is still a write as far as Observation is concerned,
            // which would rerun the inspector's body and rebuild the tree for nothing.
            if changesError != nil { changesError = nil }
            if changedFiles != answer.files { changedFiles = answer.files }
            // Only when git actually answered. A failed count leaves the last known one standing
            // rather than replacing it with "nothing local", which is a claim.
            if let local = answer.local, localWork != local { localWork = local }
            if let commits = answer.commits {
                if branchCommits != commits { branchCommits = commits }
                hasReadBranchCommits = true
            }
            adoptSelection(among: answer.files, reason: reason)
        }
    }

    /// What one refresh of the worktree came back with: the diff against the base, and what is
    /// sitting here that the remote has not got. One value because they come from one task.
    struct ChangesAnswer: Sendable {
        var files: [ChangedFile]
        var local: LocalWork?
        /// Nil when this refresh did not ask, which is every quiet poll.
        var commits: BranchCommitList?
    }

    /// Narrows or widens what the Changes tab is showing, and sends the pane back to git for it.
    ///
    /// The list has to be re-read rather than filtered: a scope is a revision the worktree is
    /// compared against, so which files differ, and by how many lines, is a different question for
    /// each one and only git can answer it.
    func setDiffScope(_ scope: DiffScope) {
        guard scope != storedDiffScope else { return }
        storedDiffScope = scope
        Task { await refreshChanges(.requested) }
    }

    /// Review comments sitting on files the current scope leaves out.
    ///
    /// Nothing here is at risk: comments live in the store keyed by workspace and path, nothing
    /// prunes them against the file list, and every one of them still goes with the next message.
    /// What they lose while a scope is narrowed is the diff they are drawn on, and a comment the
    /// reader cannot find reads as a comment that has been thrown away. So the band counts them
    /// and says so.
    var scopeNote: String? {
        diffScope.strandedNote(reviewComments, among: changedFiles)
    }

    /// A refresh can drop the file the reader had open, and the first one arrives with nothing
    /// open at all.
    ///
    /// The poll only ever takes a selection away, never hands one out. A reader who closed the
    /// diff by clicking the open row would otherwise have it reopened under them a few seconds
    /// later, and an agent adding a file would move them off the one they were reading.
    private func adoptSelection(among files: [ChangedFile], reason: ChangesRefresh) {
        if let selectedFilePath, !files.contains(where: { $0.path == selectedFilePath }) {
            self.selectedFilePath = reason == .requested ? files.first?.path : nil
        } else if selectedFilePath == nil, reason == .requested {
            selectedFilePath = files.first?.path
        }
    }

    // MARK: - Review comments

    /// The pending review: every comment written on this workspace's diffs and not yet sent.
    ///
    /// On the workspace rather than on a session, because a comment is about the worktree and the
    /// worktree is the workspace's; whichever conversation sends the review, the notes are about
    /// the same files. And in the store rather than only here, because half a review is exactly
    /// the kind of typed work that must survive switching workspace, closing the file, or
    /// quitting: the chips come back when the workspace does.
    private(set) var reviewComments: [ReviewComment] = []
    private(set) var hasReadReviewComments = false

    /// The comment being written on each file's diff, keyed by file path. Here rather than in
    /// `DiffView`'s own state because `ReviewPaneView` keys that view by path, so walking to
    /// another file, switching tab or the file leaving the changed list destroys it. The first
    /// answer to that was committing whatever had been typed on disappear, and it minted
    /// fragments: a reviewer four words into a sentence glanced at another file and came back to
    /// find those four words already committed as a review comment. A draft only joins the
    /// review through Return or the Comment button; until then it waits here, and the editor
    /// reopens holding it when its file is opened again.
    var reviewDrafts: [String: ReviewDraft] = [:]

    /// The text of every comment currently being edited in place, keyed by the comment it belongs
    /// to. Here for the same reason `reviewDrafts` is, and the reason is not hypothetical for an
    /// edit either: the band being edited sits in the same lazy stack, so scrolling it out of
    /// sight destroys it, and `ReviewPaneView` keys the whole diff by path, so glancing at another
    /// file destroys it again. An edit held as view state would lose the rewritten sentence to
    /// either, without a keystroke from the person who typed it.
    ///
    /// Keyed by id rather than by path because two comments on one file can be open at once, and
    /// closing one must not take the other's text with it.
    var reviewEdits: [ReviewCommentID: String] = [:]

    func reloadReviewComments() async {
        guard let store else { return }
        let fresh = (try? await store.reviewComments(workspaceID: workspace.id)) ?? []
        hasReadReviewComments = true
        // Conditional for the reason every reload here is: an identical write still invalidates
        // every view reading the list.
        if reviewComments != fresh { reviewComments = fresh }
    }

    /// Writes one new comment. `upsert` is right here and only here: the value is built in this
    /// call, so every column it writes is current, which is the one situation the store's
    /// upsert-vs-update rule allows it.
    func addReviewComment(
        filePath: String,
        spot: ReviewSpot,
        anchor: ReviewCommentAnchor,
        body: String
    ) async {
        guard let store else { return }
        let comment = ReviewComment(
            workspaceID: workspace.id,
            filePath: filePath,
            side: spot.side,
            anchor: anchor,
            body: body
        )
        guard let stored = try? await store.upsert(comment) else { return }
        reviewComments = (reviewComments + [stored]).sortedForReview()
    }

    /// Rewrites one comment's text. `update` and not `upsert`, and the difference is not
    /// tidiness: the value this call would have to hand `upsert` is a copy the view has been
    /// holding while somebody typed, and its anchor is the one column here that another writer
    /// moves. The comment's line is re-checked against the worktree every few seconds, so a
    /// whole-value write would carry a stale anchor back over a fresh one and pin the note to a
    /// line it has already left. The store's rule says the same in one sentence: an edit changes
    /// the column it names and no others.
    func editReviewComment(id: ReviewCommentID, body: String) async {
        guard let store else { return }
        try? await store.updateReviewCommentBody(id: id, body: body)
        guard let index = reviewComments.firstIndex(where: { $0.id == id }) else { return }
        reviewComments[index].body = body
    }

    func removeReviewComment(id: ReviewCommentID) async {
        guard let store else { return }
        try? await store.deleteReviewComment(id: id)
        reviewComments.removeAll { $0.id == id }
        // A comment that no longer exists cannot be being edited. Left behind, the buffer would
        // be a dictionary that grows for the life of the workspace and, worse, would put the old
        // text back into an editor if the same id were ever seen again.
        reviewEdits[id] = nil
    }

    /// Takes exactly the sent comments out, by id rather than by wiping the workspace, so a
    /// comment written in the moment between composing and this call is not silently thrown away
    /// with them.
    func removeReviewComments(ids: [ReviewCommentID]) async {
        guard let store, !ids.isEmpty else { return }
        for id in ids { try? await store.deleteReviewComment(id: id) }
        let sent = Set(ids)
        reviewComments.removeAll { sent.contains($0.id) }
        for id in ids { reviewEdits[id] = nil }
    }

    // MARK: - The worktree listing

    /// Every directory's children, for the All files tab, built once per workspace per launch.
    ///
    /// It lives here rather than in the view for two reasons, and the second one is a bug rather
    /// than a cost. The cost: `git ls-files` on a large worktree is a subprocess and tens of
    /// thousands of lines, and the tab re-ran it on every single arrival. The bug: the view's own
    /// `@State` outlives a workspace switch, because the tab is the same view in the same place
    /// with different contents, so between arriving at a workspace and git answering about it the
    /// tree on screen was the PREVIOUS workspace's files, listed under the new workspace's name.
    private(set) var fileTree: [String: [FileTreeNode]] = [:]
    /// Whether the listing has been read at all, so the tab can tell "nothing tracked" apart from
    /// "nobody has looked yet".
    private(set) var hasReadFileTree = false
    private var fileTreeTask: Task<Void, Never>?

    /// - Parameter force: read it again even though it has been read. For a refresh the user asked
    ///   for; an arrival never forces, which is the whole point.
    func refreshFileTree(force: Bool = false) async {
        if hasReadFileTree, !force { return }
        if let fileTreeTask, !force { return await fileTreeTask.value }

        fileTreeTask?.cancel()
        let worktree = workspace.path
        let task = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) {
                () -> [String: [FileTreeNode]] in
                let result = try? await Shell.run(
                    "git",
                    ["ls-files", "--cached", "--others", "--exclude-standard"],
                    cwd: worktree,
                    timeout: .seconds(30)
                )
                // Indexed off the main thread as well as read there. Forty thousand paths turned
                // into a dictionary is not a subprocess, but it is not free either, and the main
                // thread is what the switch is waiting on.
                return FileTreeNode.index(result?.lines ?? [])
            }.value
            guard let self, !Task.isCancelled else { return }
            if fileTree != index { fileTree = index }
            hasReadFileTree = true
            fileTreeTask = nil
        }
        fileTreeTask = task
        await task.value
    }

    func patch(for file: ChangedFile) async -> String {
        let path = workspace.path
        let base = workspace.baseBranch
        // The same scope the list was built with, or the pane opens a file the list narrowed and
        // shows it in full.
        let scope = diffScope
        return await Task.detached(priority: .userInitiated) {
            (try? await Git.patch(worktree: path, base: base, file: file, scope: scope)) ?? ""
        }.value
    }

    /// Full contents of a file in the worktree, for the All files tab.
    func contents(of relativePath: String) -> String? {
        let full = (workspace.path as NSString).appendingPathComponent(relativePath)
        return try? String(contentsOfFile: full, encoding: .utf8)
    }

    // MARK: - Pull request

    /// How stale an answer about the pull request an arrival will settle for.
    ///
    /// Arriving at a workspace used to run `gh auth status` and `gh pr view` every single time,
    /// which is two subprocesses and two round trips to GitHub for a fact that changes when
    /// somebody pushes, reviews or merges. Measured on this machine: 640ms to 1.1s per arrival,
    /// all of it after the window had finished drawing, and all of it repeated by flicking between
    /// two workspaces.
    ///
    /// Only an arrival accepts a cached answer. Everything that has a reason to believe the answer
    /// changed asks again with no age at all: a finished turn, the bar's own poll, and the button
    /// that creates one.
    static let pullRequestArrivalMaxAge = Duration.seconds(30)

    /// - Parameter maxAge: how old a cached answer may be. Zero always asks GitHub.
    func refreshPullRequest(maxAge: Duration = .zero) async {
        pullRequestTask?.cancel()
        let asked = workspace

        let task = Task.detached(priority: .utility) {
            await GitHubBridge.pullRequest(for: asked, maxAge: maxAge)
        }
        pullRequestTask = task
        // Only when there is nothing to show, for the same reason the changed file list only
        // spins when it is empty.
        if pullRequest == nil { isLoadingPullRequest = true }

        let fresh = await task.value

        guard pullRequestTask == task, !task.isCancelled else { return }
        pullRequestTask = nil
        if pullRequest != fresh { pullRequest = fresh }
        isLoadingPullRequest = false
        SwitchTrace.mark("pullRequest.loaded", workspace: workspace.id)
    }

    /// Asks the workspace's agent to open the pull request, instead of running `gh` from here.
    ///
    /// The agent already holds the things a pull request needs and Bloom does not: this project's
    /// commit message conventions, its PR template, and the ability to answer a rejected push
    /// rather than surfacing it as a failed shell command. So the button composes a turn and sends
    /// it down exactly the path the composer uses, which is also why the request appears in the
    /// transcript and streams back like anything else the user typed.
    ///
    /// Returns nil on success, or the sentence to put in front of the user.
    func requestPullRequest(overrides: PromptOverrides = PromptOverrides()) async -> String? {
        // One agent, one turn. Sending into a running turn would interleave with whatever the user
        // asked for a moment ago, and the runner writes both into the same transcript.
        guard !isRunning else {
            return "\(workspace.name) is still working. Wait for the turn to finish, then ask again."
        }

        let template = overrides.template(for: .createPullRequest)
        let wanted = Set(PromptTemplate.variableNames(in: template))

        // Only what this template actually asks for. The built-in one names the target branch and
        // nothing else, and reading every session's first turn back out of the store to fill a
        // variable nobody used was a page of work per press.
        if wanted.contains(PromptRegistry.CreatePullRequest.changes) {
            await refreshChanges()
        }

        guard let session = await sessionForPullRequest() else {
            return "Could not open a session in \(workspace.name) to send the request to."
        }

        let context = PullRequestPromptContext(
            workspaceName: workspace.name,
            branch: workspace.branch,
            baseBranch: workspace.baseBranch,
            task: wanted.contains(PromptRegistry.CreatePullRequest.task) ? await openingPrompt() : "",
            changes: wanted.contains(PromptRegistry.CreatePullRequest.changes)
                ? PullRequestPromptContext.changeSummary(changedFiles)
                : ""
        )
        let render = context.render(template: template)

        // Bring the session forward first: the turn is about to start streaming, and a user who
        // pressed a button in the inspector should be looking at the answer to it.
        activeSessionID = session.id
        isExpectingPullRequest = true
        await transcript(for: session).submit(await pullRequestTurn(text: render.text))
        return nil
    }

    /// Asks this workspace's agent to commit what is outstanding and push the branch.
    ///
    /// The agent rather than Bloom, and the reasoning is the same one that put pull request
    /// creation here: a commit needs a message, and Bloom knows only that a file changed. The
    /// agent knows what it changed, how this project words a commit and what to do when the push
    /// is rejected. A message this app invented would be in the repository's history forever.
    ///
    /// The same guard and the same route as `requestPullRequest`, so both buttons in the strip
    /// behave identically: one agent, one turn, and the session comes forward so the reader is
    /// looking at the answer to the button they pressed.
    ///
    /// Returns nil on success, or the sentence to put in front of the user.
    func requestPush(overrides: PromptOverrides = PromptOverrides()) async -> String? {
        guard !isRunning else {
            return "\(workspace.name) is still working. Wait for the turn to finish, then ask again."
        }

        let template = overrides.template(for: .pushLocalWork)
        let wanted = Set(PromptTemplate.variableNames(in: template))

        if wanted.contains(PromptRegistry.PushLocalWork.changes) {
            await refreshChanges()
        }

        guard let session = await sessionForPullRequest() else {
            return "Could not open a session in \(workspace.name) to send the request to."
        }

        let render = PromptTemplate.render(template, values: [
            PromptRegistry.PushLocalWork.workspace: workspace.name,
            PromptRegistry.PushLocalWork.branch: workspace.branch,
            PromptRegistry.PushLocalWork.baseBranch: workspace.baseBranch,
            PromptRegistry.PushLocalWork.changes:
                PullRequestPromptContext.changeSummary(changedFiles),
        ])

        activeSessionID = session.id
        // No attachment. The pull request instructions are about opening a pull request, and
        // there is already one open by the time this button exists.
        await transcript(for: session).submit(render.text)
        return nil
    }

    /// Asks the workspace's agent to merge the pull request, instead of running `gh` from here.
    ///
    /// The last of the three buttons in the strip to move, and the one with the most riding on it.
    /// Bloom used to run `gh pr merge` and then `git push --delete` behind it, catch a `ShellError`
    /// and put a sentence in a notice. That arrangement had no answer for the case that actually
    /// happens: GitHub refuses, because a required check has not finished or a review is missing,
    /// and what the person needed was a conversation rather than a red box. An agent gets the same
    /// refusal in words, in the transcript, with the command it ran above it, and can say what to
    /// do next.
    ///
    /// It also puts the merge behind the permission mode the person already chose. A button
    /// running `gh pr merge` is outside all of that by construction; a turn is not.
    ///
    /// The same guard and the same route as `requestPullRequest` and `requestPush`, so all three
    /// buttons in the strip behave identically.
    ///
    /// Returns nil on success, or the sentence to put in front of the user.
    func requestMerge(
        _ pullRequest: PullRequest,
        method: GitHub.MergeMethod,
        overrides: PromptOverrides = PromptOverrides()
    ) async -> String? {
        guard !isRunning else {
            return "\(workspace.name) is still working. Wait for the turn to finish, then press "
                + "Merge again."
        }

        guard let session = await sessionForPullRequest(titledIfNew: "Merge") else {
            return "Could not open a session in \(workspace.name) to send the request to."
        }

        let context = MergePromptContext(
            workspaceName: workspace.name,
            number: pullRequest.number,
            title: pullRequest.title,
            branch: pullRequest.branch,
            baseBranch: workspace.baseBranch,
            method: method
        )
        let render = context.render(template: overrides.template(for: .mergePullRequest))

        activeSessionID = session.id
        await transcript(for: session).submit(mergeTurn(text: render.text))
        return nil
    }

    /// The merge turn, with the instructions named in it.
    ///
    /// Synchronous where `pullRequestTurn` is not, because `MergeInstructions` has no reclaim step
    /// to await. See the note on that type for why it does not have one.
    ///
    /// When the file cannot be written the instructions go into the message itself, which matters
    /// more here than it does for creating a pull request: this is the turn whose instructions say
    /// what not to do to somebody's repository, and a read-only checkout is not a reason to send
    /// it without them.
    private func mergeTurn(text: String) -> String {
        if let path = MergeInstructions.ensure(in: workspace.path) {
            return MergeInstructions.asking(text, toFollow: path)
        }
        return text + "\n\n" + MergeInstructions.defaultMarkdown
    }

    /// The turn that goes down the wire, with the instructions named in it.
    ///
    /// The path goes in the sentence that asks for it, which is where every other file Bloom sends
    /// now goes: a pull request request is a user turn like any other, so it says what it wants in
    /// words and names the file inside them, and the agent is handed a path inside its own working
    /// directory. See `PullRequestInstructions.asking`.
    ///
    /// When the file cannot be written, the instructions go into the message itself. A read-only
    /// checkout is a reason to say it differently, not a reason for the button to stop working.
    private func pullRequestTurn(text: String) async -> String {
        if let path = await PullRequestInstructions.ensure(in: workspace.path) {
            return PullRequestInstructions.asking(text, toFollow: path)
        }
        return text + "\n\n" + PullRequestInstructions.defaultMarkdown
    }

    /// A workspace whose agent was never started still has a button to press. Rather than doing
    /// nothing, it gets the session it would have got the first time somebody typed into it.
    ///
    /// - Parameter title: what a session created here is called. Named by the caller because the
    ///   three buttons in the strip all land here and a merge that opens a chat called "Create
    ///   pull request" is a lie in the sidebar for as long as that session lives.
    private func sessionForPullRequest(titledIfNew title: String = "Create pull request") async -> Session? {
        if let activeSession { return activeSession }
        await reloadSessions()
        if let activeSession { return activeSession }
        return await createSession(title: title)
    }

    /// What this workspace was created to do, read back out of the oldest session's first user
    /// turn. Sessions come back in sort order, so the first one that has a user turn is the one
    /// the workspace opened with.
    ///
    /// Without the files named in it. This becomes the `task:` line of the prompt that writes the
    /// pull request, and a scratch path under `.bloom/attachments` is invisible to git, means
    /// nothing to a reviewer, and is exactly the sort of thing that ends up quoted in a
    /// description. What the workspace was for is the sentence, not the screenshot.
    ///
    /// Both forms are taken off: turns sent before attachments moved into the sentence carry a
    /// trailer at the end, and those are still in the database.
    private func openingPrompt() async -> String {
        guard let store else { return "" }
        for session in sessions {
            let messages = (try? await store.messages(sessionID: session.id, limit: 200)) ?? []
            guard let first = messages.first(where: { $0.kind == .user }),
                  let text = UserTurnPayload.text(from: first.payload) else { continue }
            return AttachmentDraft.withoutAttachments(AttachmentTrailer.split(text).body)
        }
        return ""
    }

    // MARK: - Housekeeping

    /// The window has arrived on this workspace.
    ///
    /// Two halves, and which half a piece of work is in is the whole of what makes a switch feel
    /// immediate. Before this returns: nothing that is already in hand. After it, in a task of its
    /// own: everything that needs SQLite, a subprocess or the network.
    ///
    /// The first visit of a launch is the one exception, and it is honest about itself. There are
    /// no sessions yet, so there is no transcript to draw and nothing to be quick about; the read
    /// is waited for because the alternative is an empty pane that fills in a beat later, which is
    /// the flash this whole arrangement exists to avoid. Every arrival after that draws from the
    /// sessions, the rows and the file list this model is already holding, and the refreshes
    /// below only ever correct what is already on screen.
    ///
    /// This used to be four `await`s in a row, so a return to a workspace waited on a session
    /// query, then on `git diff` against the worktree, then on a write to the workspace row,
    /// before the last of them started asking GitHub. Measured on a forty thousand file worktree:
    /// the file list landed 970ms after the click, and the row that says the workspace has been
    /// read was written after that.
    func onAppear() async {
        SwitchTrace.mark("onAppear.start", workspace: workspace.id)
        // Whether the store has answered, rather than whether the answer was empty. A workspace
        // whose conversations have all been archived is not on its first visit forever.
        let isFirstVisit = !hasReadSessions
        if isFirstVisit { await reloadSessions() }
        SwitchTrace.mark("sessions.loaded", workspace: workspace.id)

        // One task per arrival, and the previous one is cancelled. Leaving a workspace while its
        // git call is in flight is the ordinary case, not the exception: it is what switching
        // quickly between two workspaces IS.
        arrivalTask?.cancel()
        arrivalTask = Task { [weak self] in
            guard let self else { return }
            if !isFirstVisit { await reloadSessions() }
            guard !Task.isCancelled else { return }
            // Once per launch: only this app writes review comments, so after the first read the
            // in-memory list is the truth and re-reading it on every arrival buys nothing.
            if !hasReadReviewComments { await reloadReviewComments() }
            guard !Task.isCancelled else { return }
            // Concurrently, because neither is waiting for anything the other knows. The read
            // mark used to be written after `git` had finished walking the worktree.
            async let changes: Void = refreshChanges()
            async let read: Void = app.markRead(workspace)
            _ = await (changes, read)
            SwitchTrace.mark("changes.loaded", workspace: self.workspace.id)
            SwitchTrace.markOnScreen("changes.loaded", workspace: self.workspace.id)
            guard !Task.isCancelled else { return }
            // Last, and allowed to answer from the cache. This is the only part of an arrival that
            // goes to the network, so it is the only part that must never be waited on by
            // anything else. See `refreshPullRequest`.
            await refreshPullRequest(maxAge: Self.pullRequestArrivalMaxAge)
        }
    }

    /// Called when an agent turn finishes, to refresh everything derived from the filesystem.
    func onTurnFinished() async {
        await refreshChanges()
        if let manager = app.manager {
            await manager.refreshDiffStat(workspace: workspace)
        }

        // The turn Create pull request sent is waited on rather than fired and forgotten, because
        // what came of it is the answer to a button somebody pressed. Every other turn keeps the
        // refresh it always had: a background poll nobody is standing over.
        guard isExpectingPullRequest else {
            Task { await refreshPullRequest() }
            return
        }
        isExpectingPullRequest = false
        await refreshPullRequest()
        if pullRequest == nil {
            pullRequestShortfalls += 1
        }
    }
}


/// A thread-safe hand-off for streamed output.
///
/// The producer is a subprocess reader on some background thread and the consumer is the main
/// actor. Batching between them is what keeps a chatty script from swamping the UI.
///
/// A `Mutex` rather than a lock next to an unprotected array: the buffer is then unreachable
/// except through the lock, so the type is `Sendable` on the compiler's terms rather than on a
/// promise, and `drain` cannot accidentally read outside it.
final class LineBuffer: Sendable {
    private let pending = Mutex<[String]>([])

    func append(_ line: String) {
        pending.withLock { $0.append(line) }
    }

    func drain() -> [String] {
        pending.withLock { lines in
            defer { lines.removeAll(keepingCapacity: true) }
            return lines
        }
    }
}

/// A review comment mid-composition: where it will attach, the evidence captured when its
/// editor opened, and the text so far. See `WorkspaceModel.reviewDrafts` for why it outlives
/// the diff view that is editing it.
struct ReviewDraft: Hashable {
    var spot: ReviewSpot
    var anchor: ReviewCommentAnchor
    var text: String = ""
}
