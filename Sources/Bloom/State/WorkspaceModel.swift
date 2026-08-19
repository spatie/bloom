import SwiftUI
import Observation
import Synchronization
import BloomCore

/// Which tab the bottom panel of the inspector is showing.
enum BottomTab: Hashable {
    case setup
    case run(String)
    case terminal(String)

    /// "Whichever terminal tab is first." A workspace picks its bottom tab before its terminal
    /// tabs have been read from the store, so it cannot name one by id yet.
    static let firstTerminal = BottomTab.terminal("")
}

/// A git failure carried back across a task boundary. `any Error` is not `Sendable`, and the only
/// part of it the UI shows is the message.
struct GitFailure: Error, Sendable {
    var message: String
}

/// Which tab the top of the inspector is showing.
enum InspectorTab: String, Hashable, CaseIterable {
    case allFiles = "All files"
    case changes = "Changes"
    case checks = "Checks"
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

    /// Switching tab is the moment a transcript should come into existence, rather than the
    /// moment a view body happens to ask for one. Preparing it here keeps model creation, which
    /// is an observable write, out of the render pass.
    var activeSessionID: String? {
        get { storedActiveSessionID }
        set {
            storedActiveSessionID = newValue
            prepareActiveTranscript()
        }
    }

    private var storedActiveSessionID: String?

    /// One transcript per session, built on demand.
    private var transcripts: [String: TranscriptModel] = [:]

    // Inspector.
    var inspectorTab: InspectorTab = .changes
    var changedFiles: [ChangedFile] = []
    var selectedFilePath: String?
    var isLoadingChanges = false
    /// Why the last refresh could not answer. Non-nil means `changedFiles` is the last list git was
    /// able to produce, not what the worktree looks like now.
    var changesError: String?
    var pullRequest: PullRequest?
    var isLoadingPullRequest = false

    // Bottom panel.
    var bottomTab: BottomTab = .firstTerminal
    var setupOutput: String = ""
    /// The tail Bloom keeps in memory. A setup script that prints a megabyte is not unusual, and
    /// none of it is worth re-rendering on every append.
    static let setupLogLimit = 200_000
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
            durationMS: setupDurationMS
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

    // Layout.

    var port: Int = 0

    /// The in-flight refreshes, so a newer one can cancel the one it replaces. Two overlapping
    /// refreshes both claim `isLoadingChanges`, and the slower one finishing last would otherwise
    /// write its stale answer over the fresh one.
    private var changesTask: Task<Result<[ChangedFile], GitFailure>, Never>?
    private var pullRequestTask: Task<PullRequest?, Never>?
    /// A setup script can run for minutes (`composer install`, `npm ci`). Without a handle,
    /// archiving mid-setup cannot stop it and it outlives the app.
    private var setupTask: Task<Void, Never>?

    init(workspace: Workspace, app: AppModel) {
        self.workspace = workspace
        self.app = app
        self.setupOutput = workspace.setupLog
    }

    var store: Store? { app.store }
    var repo: Repo? { app.repo(for: workspace) }

    // MARK: - Sessions

    var activeSession: Session? {
        guard let activeSessionID else { return sessions.first }
        return sessions.first { $0.id == activeSessionID } ?? sessions.first
    }

    func reloadSessions() async {
        guard let store else { return }
        sessions = (try? await store.sessions(workspaceID: workspace.id)) ?? []
        if activeSessionID == nil || !sessions.contains(where: { $0.id == activeSessionID }) {
            activeSessionID = sessions.first?.id
        }
        prepareActiveTranscript()
    }

    @discardableResult
    func createSession(title: String = "New session") async -> Session? {
        guard let store else { return nil }
        let session = Session(
            workspaceID: workspace.id,
            title: title,
            sortOrder: sessions.count
        )
        guard let stored = try? await store.upsert(session) else { return nil }
        await reloadSessions()
        activeSessionID = stored.id
        return stored
    }

    /// Moves a session to another place in the strip, and writes the whole workspace's order back.
    ///
    /// The list is updated here first so the tab lands under the pointer on the frame the drop
    /// happens, rather than a round trip through SQLite later.
    func reorderSession(_ session: Session, to index: Int) async {
        guard let store, let from = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        var ordered = sessions
        let moved = ordered.remove(at: from)
        ordered.insert(moved, at: min(max(index, 0), ordered.count))
        for (order, item) in ordered.enumerated() { ordered[order] = item.with { $0.sortOrder = order } }
        sessions = ordered
        try? await store.reorderSessions(ids: ordered.map(\.id))
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
        _ = try? await store.upsert(session.with {
            $0.archivedAt = Date()
        })
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
    func existingTranscript(for sessionID: String) -> TranscriptModel? {
        transcripts[sessionID]
    }

    /// Builds a session's transcript if this launch has not seen it yet. Called from a task, never
    /// from a body, for the reason `transcript(for:)` spells out.
    func prepareTranscript(for sessionID: String) {
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

    func stopEverything() {
        for transcript in transcripts.values { transcript.stop() }
        setupTask?.cancel()
        setupTask = nil
        changesTask?.cancel()
        pullRequestTask?.cancel()
        // A cancelled refresh returns before it clears its own flag, so the spinner would spin
        // for the rest of the launch.
        isLoadingChanges = false
        isLoadingPullRequest = false
        isRunningSetup = false
    }

    /// The workspace itself is going away, so the runners go too. `stopEverything` only ends the
    /// turns, and a transcript left holding a live runner would keep it for the rest of the launch.
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
        changesTask?.cancel()
        pullRequestTask?.cancel()
        for transcript in transcripts.values {
            await transcript.shutdown()
        }
    }

    // MARK: - First run

    /// Owns the setup run so archiving, or quitting, can stop a `composer install` that is only
    /// halfway through. Cancellation reaches the script itself through `StreamingProcess.lines`.
    /// `prompt` is optional because a terminal workspace has no opening message: it still runs
    /// the setup script, it simply has nothing to say to an agent afterwards.
    func startSetupThenSend(prompt: String?, repo: Repo) {
        setupTask?.cancel()
        setupGeneration += 1
        let generation = setupGeneration
        setupTask = Task { [weak self] in
            await self?.runSetupThenSend(prompt: prompt, repo: repo)
            // Only clear the handle if it is still this run's. A cancelled setup finishes after
            // the one that replaced it has already been stored, and clearing unconditionally
            // dropped the live handle, which left the new run with nothing able to cancel it.
            guard let self, self.setupGeneration == generation else { return }
            self.setupTask = nil
        }
    }

    /// Which setup run the stored `setupTask` belongs to.
    private var setupGeneration = 0

    /// Runs the setup script, streaming into the Setup tab, then sends the opening prompt.
    func runSetupThenSend(prompt: String?, repo: Repo) async {
        guard let manager = app.manager else { return }

        // Off the main actor: this reads and parses up to six files from disk, and it runs at the
        // moment a workspace is created, which is exactly when the window must stay responsive.
        let repoPath = repo.path
        let settings = await Task.detached(priority: .userInitiated) {
            SettingsLoader.load(repo: repoPath)
        }.value

        if settings.setupScript != nil {
            isRunningSetup = true
            setupStartedAt = .now
            setupDurationMS = nil
            bottomTab = .setup
            setupOutput = ""
            // A machine with no free block left is not a reason to refuse to run setup. The script
            // simply gets no port to bind, which it can decide for itself what to do about.
            port = (try? PortAllocator.allocate(taken: [])) ?? 0

            // Setup scripts are chatty: `composer install` and `bun install` together are
            // thousands of lines. Hopping to the main actor once per line, each time appending to
            // a string that keeps growing, is quadratic work on the main queue and it beachballs
            // the whole window. Lines are collected off-actor and flushed a few times a second.
            let buffer = LineBuffer()
            let flusher = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self else { return }
                    self.appendSetupOutput(buffer.drain())
                }
            }

            let succeeded = await manager.runSetup(
                workspace: workspace, repo: repo, port: port
            ) { line in
                buffer.append(line)
            }

            flusher.cancel()
            appendSetupOutput(buffer.drain())
            isRunningSetup = false
            setupDurationMS = setupStartedAt.map { Int(Date.now.timeIntervalSince($0) * 1000) }

            // Archiving or quitting cancels this task. Starting an agent in a worktree that is on
            // its way out is the one thing that must not happen here.
            guard !Task.isCancelled else { return }

            if !succeeded {
                app.alert = BloomAlert(
                    title: "Setup failed for \(workspace.name)",
                    message: "The agent was not started. Check the Setup tab for the output."
                )
                NotificationService.shared.setupFailed(workspace: workspace)
                bottomTab = .setup
                return
            }
            bottomTab = .firstTerminal
        }

        await reloadSessions()
        guard !Task.isCancelled, let prompt, let session = activeSession else { return }
        await transcript(for: session).send(prompt)
    }

    /// Appends a batch, keeping only the tail. Called from the flusher, never per line.
    func appendSetupOutput(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        setupOutput += lines.joined(separator: "\n") + "\n"
        if setupOutput.count > Self.setupLogLimit {
            setupOutput = String(setupOutput.suffix(Self.setupLogLimit))
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

        let task = Task.detached(priority: .userInitiated) { () -> Result<[ChangedFile], GitFailure> in
            do {
                return .success(try await Git.changedFiles(worktree: path, base: base))
            } catch {
                return .failure(GitFailure(message: error.readableMessage))
            }
        }
        changesTask = task
        if reason == .requested { isLoadingChanges = true }

        let outcome = await task.value

        // A newer refresh started while this one was in git, or the workspace is going away. Either
        // way this answer is the stale one, and writing it would undo the fresh one.
        guard changesTask == task, !task.isCancelled else { return }
        changesTask = nil
        // Cleared whatever this refresh asked for, because a quiet one can be the last to land
        // after a requested one raised the flag, and then only it can put the flag down again.
        isLoadingChanges = false

        switch outcome {
        case .failure(let failure):
            // Git failing says nothing about the worktree. Replacing the list with an empty one
            // would show the user a clean workspace, which is the one answer that is certainly
            // wrong, so the last known list stays and the failure is reported instead.
            changesError = failure.message

        case .success(let files):
            // Only when it actually moved. `AppModel`'s poll lands here every six seconds, and a
            // write of an identical list is still a write as far as Observation is concerned,
            // which would rerun the inspector's body and rebuild the tree for nothing.
            if changesError != nil { changesError = nil }
            if changedFiles != files { changedFiles = files }
            adoptSelection(among: files, reason: reason)
        }
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

    func patch(for file: ChangedFile) async -> String {
        let path = workspace.path
        let base = workspace.baseBranch
        return await Task.detached(priority: .userInitiated) {
            (try? await Git.patch(worktree: path, base: base, file: file)) ?? ""
        }.value
    }

    /// Full contents of a file in the worktree, for the All files tab.
    func contents(of relativePath: String) -> String? {
        let full = (workspace.path as NSString).appendingPathComponent(relativePath)
        return try? String(contentsOfFile: full, encoding: .utf8)
    }

    // MARK: - Pull request

    func refreshPullRequest() async {
        pullRequestTask?.cancel()
        let branch = workspace.branch
        let path = workspace.path

        let task = Task.detached(priority: .utility) {
            await GitHubBridge.pullRequest(branch: branch, worktree: path)
        }
        pullRequestTask = task
        isLoadingPullRequest = true

        let fresh = await task.value

        guard pullRequestTask == task, !task.isCancelled else { return }
        pullRequestTask = nil
        pullRequest = fresh
        isLoadingPullRequest = false
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

        // The list of changed files goes into the prompt, so it has to describe the worktree now
        // rather than whenever the inspector last looked at it.
        await refreshChanges()

        guard let session = await sessionForPullRequest() else {
            return "Could not open a session in \(workspace.name) to send the request to."
        }

        let context = PullRequestPromptContext(
            workspaceName: workspace.name,
            branch: workspace.branch,
            baseBranch: workspace.baseBranch,
            task: await openingPrompt(),
            changes: PullRequestPromptContext.changeSummary(changedFiles)
        )
        let render = context.render(template: overrides.template(for: .createPullRequest))

        // Bring the session forward first: the turn is about to start streaming, and a user who
        // pressed a button in the inspector should be looking at the answer to it.
        activeSessionID = session.id
        await transcript(for: session).send(render.text)
        return nil
    }

    /// A workspace whose agent was never started still has a button to press. Rather than doing
    /// nothing, it gets the session it would have got the first time somebody typed into it.
    private func sessionForPullRequest() async -> Session? {
        if let activeSession { return activeSession }
        await reloadSessions()
        if let activeSession { return activeSession }
        return await createSession(title: "Create pull request")
    }

    /// What this workspace was created to do, read back out of the oldest session's first user
    /// turn. Sessions come back in sort order, so the first one that has a user turn is the one
    /// the workspace opened with.
    ///
    /// Without the attachment trailer. This becomes the `task:` line of the prompt that writes the
    /// pull request, and a scratch path under `.bloom/attachments` is invisible to git, means
    /// nothing to a reviewer, and is exactly the sort of thing that ends up quoted in a
    /// description. What the workspace was for is the sentence, not the screenshot.
    private func openingPrompt() async -> String {
        guard let store else { return "" }
        for session in sessions {
            let messages = (try? await store.messages(sessionID: session.id, limit: 200)) ?? []
            guard let first = messages.first(where: { $0.kind == .user }),
                  let text = UserTurnPayload.text(from: first.payload) else { continue }
            return AttachmentTrailer.split(text).body
        }
        return ""
    }

    // MARK: - Housekeeping

    func onAppear() async {
        await reloadSessions()
        await refreshChanges()
        await app.markRead(workspace)
        Task { await refreshPullRequest() }
    }

    /// Called when an agent turn finishes, to refresh everything derived from the filesystem.
    func onTurnFinished() async {
        await refreshChanges()
        if let manager = app.manager {
            await manager.refreshDiffStat(workspace: workspace)
        }
        await app.reload()
        Task { await refreshPullRequest() }
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
