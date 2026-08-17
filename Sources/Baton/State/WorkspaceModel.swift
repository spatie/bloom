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

    private var changesTask: Task<Void, Never>?
    private var pullRequestTask: Task<Void, Never>?

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
        transcripts[session.id]?.stop()
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
        changesTask?.cancel()
        pullRequestTask?.cancel()
    }

    // MARK: - First run

    /// Runs the setup script, streaming into the Setup tab, then sends the opening prompt.
    func runSetupThenSend(prompt: String, repo: Repo) async {
        guard let manager = app.manager else { return }

        let settings = SettingsLoader.load(repo: repo.path)
        if settings.setupScript != nil {
            isRunningSetup = true
            bottomTab = .setup
            setupOutput = ""
            port = PortAllocator.allocate(taken: [])

            let succeeded = await manager.runSetup(
                workspace: workspace, repo: repo, port: port
            ) { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    self.setupOutput += line + "\n"
                }
            }
            isRunningSetup = false

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
        if let session = activeSession {
            await transcript(for: session).send(prompt)
        }
    }

    // MARK: - Changes

    func refreshChanges() async {
        changesTask?.cancel()
        isLoadingChanges = true
        let path = workspace.path
        let base = workspace.baseBranch

        let files = await Task.detached(priority: .userInitiated) {
            (try? await Git.changedFiles(worktree: path, base: base)) ?? []
        }.value

        changedFiles = files
        isLoadingChanges = false
        if let selectedFilePath, !files.contains(where: { $0.path == selectedFilePath }) {
            self.selectedFilePath = files.first?.path
        } else if selectedFilePath == nil {
            selectedFilePath = files.first?.path
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
        isLoadingPullRequest = true
        defer { isLoadingPullRequest = false }
        pullRequest = await GitHubBridge.pullRequest(
            branch: workspace.branch, worktree: workspace.path
        )
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
