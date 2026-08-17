import SwiftUI
import Observation
import BatonCore

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
    var activeSessionID: String?

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
    var isBottomPanelVisible = true
    var setupOutput: String = ""
    var isRunningSetup = false

    // Layout.
    var isInspectorVisible = true

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
    func transcript(for session: Session) -> TranscriptModel {
        if let existing = transcripts[session.id] {
            existing.session = session
            return existing
        }
        let model = TranscriptModel(session: session, workspace: workspace, app: app)
        transcripts[session.id] = model
        Task { await model.load() }
        return model
    }

    var activeTranscript: TranscriptModel? {
        activeSession.map { transcript(for: $0) }
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
    func startSetupThenSend(prompt: String, repo: Repo) {
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            await self?.runSetupThenSend(prompt: prompt, repo: repo)
            self?.setupTask = nil
        }
    }

    /// Runs the setup script, streaming into the Setup tab, then sends the opening prompt.
    func runSetupThenSend(prompt: String, repo: Repo) async {
        guard let manager = app.manager else { return }

        let settings = SettingsLoader.load(repo: repo.path)
        if settings.setupScript != nil {
            isRunningSetup = true
            bottomTab = .setup
            setupOutput = ""
            // A machine with no free block left is not a reason to refuse to run setup. The script
            // simply gets no port to bind, which it can decide for itself what to do about.
            port = (try? PortAllocator.allocate(taken: [])) ?? 0

            let succeeded = await manager.runSetup(
                workspace: workspace, repo: repo, port: port
            ) { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    self.setupOutput += line + "\n"
                }
            }
            isRunningSetup = false

            // Archiving or quitting cancels this task. Starting an agent in a worktree that is on
            // its way out is the one thing that must not happen here.
            guard !Task.isCancelled else { return }

            if !succeeded {
                app.alert = BatonAlert(
                    title: "Setup failed for \(workspace.name)",
                    message: "The agent was not started. Check the Setup tab for the output."
                )
                bottomTab = .setup
                return
            }
            bottomTab = .firstTerminal
        }

        await reloadSessions()
        guard !Task.isCancelled, let session = activeSession else { return }
        await transcript(for: session).send(prompt)
    }

    // MARK: - Changes

    func refreshChanges() async {
        changesTask?.cancel()
        let path = workspace.path
        let base = workspace.baseBranch

        let task = Task.detached(priority: .userInitiated) { () -> Result<[ChangedFile], GitFailure> in
            do {
                return .success(try await Git.changedFiles(worktree: path, base: base))
            } catch {
                return .failure(GitFailure(message: "\(error)"))
            }
        }
        changesTask = task
        isLoadingChanges = true

        let outcome = await task.value

        // A newer refresh started while this one was in git, or the workspace is going away. Either
        // way this answer is the stale one, and writing it would undo the fresh one.
        guard changesTask == task, !task.isCancelled else { return }
        changesTask = nil
        isLoadingChanges = false

        switch outcome {
        case .failure(let failure):
            // Git failing says nothing about the worktree. Replacing the list with an empty one
            // would show the user a clean workspace, which is the one answer that is certainly
            // wrong, so the last known list stays and the failure is reported instead.
            changesError = failure.message

        case .success(let files):
            changesError = nil
            changedFiles = files
            if let selectedFilePath, !files.contains(where: { $0.path == selectedFilePath }) {
                self.selectedFilePath = files.first?.path
            } else if selectedFilePath == nil {
                selectedFilePath = files.first?.path
            }
        }
    }

    var selectedFile: ChangedFile? {
        changedFiles.first { $0.path == selectedFilePath }
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
