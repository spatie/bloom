import Foundation
import Observation
import BloomCore

@MainActor
@Observable
final class RemoteWorkspaceFileListing: WorkspacePaneModel {
    var browserReviews: [String: BrowserRegionCapture] = [:]
    var workspace: Workspace
    private unowned let server: ServerWindowModel
    private unowned let app: AppModel
    private let endpoint: ServerEndpoint?
    @ObservationIgnored private var indexedPaths: [String] = []
    @ObservationIgnored private var indexedTree: [String: [FileTreeNode]] = [:]
    private(set) var hasReadFileTree = false
    @ObservationIgnored private var panePositions: [TranscriptPaneState.Key: TranscriptPaneState] = [:]
    private var sessionOrder: [SessionID] = []
    var reviewDestinationID: SessionID?
    var reviewDestination: Session? {
        let id = ReviewDestination.resolved(chosen: reviewDestinationID, active: activeSessionID, sessions: sessions.map(\.id))
        return sessions.first { $0.id == id }
    }
    var reviewDrafts: [String: ReviewDraft] = [:]
    var reviewEdits: Set<ReviewCommentID> = []
    let reviewText = ReviewTextHost()
    private var presentations = DiffPresentationCache()
    private var patchCache: [String: (revision: String, patch: String)] = [:]
    private var patchOrder: [String] = []
    private var patchBytes = 0
    private var heldContents: [String: String] = [:]
    var reviewComments: [ReviewComment] { [] }
    var supportsReviewComments: Bool { false }
    var changesGeneration: Int { server.review.contentGeneration }
    var repo: Repo? { server.catalogue?.repositories.first { $0.id == workspace.repoID } }
    let fileEdits: FileEditSession

    init(workspace: Workspace, server: ServerWindowModel, app: AppModel) {
        self.workspace = workspace
        self.server = server
        self.app = app
        endpoint = server.endpoint
        fileEdits = server.fileEdits(for: workspace)
    }

    var localWorkspaceModel: WorkspaceModel? { nil }
    var remoteServer: ServerWindowModel? { server }
    var sessions: [Session] {
        get {
            let found = server.catalogue?.sessions.filter { $0.workspaceID == workspace.id && $0.archivedAt == nil } ?? []
            guard !sessionOrder.isEmpty else { return found }
            let ranks = Dictionary(sessionOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            return found.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
        }
        set { server.catalogue?.sessions = (server.catalogue?.sessions.filter { $0.workspaceID != workspace.id } ?? []) + newValue }
    }
    var activeSessionID: SessionID? {
        get { server.activeSession(in: workspace.id) }
        set { server.activateSession(newValue, in: workspace.id) }
    }
    var activeSession: Session? { sessions.first { $0.id == activeSessionID } }
    var activeTranscript: TranscriptModel? { activeSessionID.flatMap(existingTranscript(for:)) }
    var hasReadSessions: Bool { server.catalogue != nil }
    var isRunningSetup: Bool { workspace.setupState == .running }
    var port: Int { workspace.port }
    func ensurePort() async -> Int { workspace.port }
    func browserAddress() async -> String {
        do {
            if case .text(let address) = try await read(.workspace(workspaceID: workspace.id, action: .browserAddress)) { return address }
        } catch { if !Task.isCancelled { server.error = error.localizedDescription } }
        return WorkspacePreview.address(port: workspace.port) ?? ""
    }
    func onAppear() async {
        await reloadSessions()
        if let id = activeSessionID { prepareTranscript(for: id) }
    }
    func reloadSessions() async {
        do {
            if case .catalogue(let value) = try await read(.catalogue) {
                server.catalogue = value
                if let fresh = value.workspaces.first(where: { $0.id == workspace.id }) { workspace = fresh }
                if !sessions.contains(where: { $0.id == activeSessionID }) { activeSessionID = sessions.first?.id }
            }
        } catch { if !Task.isCancelled { server.error = error.localizedDescription } }
    }
    func makePaneSession(title: String?, controls: ComposerControls?, draft: String) async -> Session? {
        let choices = controls ?? activeSession.map { ComposerControls(session: $0, isFastMode: false, outputStyle: OutputStyle.defaultName) }
            ?? ComposerControls(model: server.agentModel, effort: server.effort, agentKind: server.agent, permissionMode: server.permissionMode)
        guard case .created(let created, _, _) = await perform(.workspace(workspaceID: workspace.id,
            action: .newSession(agent: choices.agentKind, model: choices.model, effort: choices.effort, permissionMode: choices.permissionMode))) else { return nil }
        server.saveRemoteDraft(draft, sessionID: created.id)
        if let title { _ = await perform(.renameSession(sessionID: created.id, title: title)) }
        if controls != nil { _ = await perform(.setComposer(sessionID: created.id, controls: choices)) }
        await reloadSessions()
        activeSessionID = created.id
        prepareTranscript(for: created.id)
        return sessions.first { $0.id == created.id } ?? created
    }
    func renameSession(_ session: Session, title: String) async {
        _ = await perform(.renameSession(sessionID: session.id, title: title))
        await reloadSessions()
    }
    func closeSession(_ session: Session) async {
        guard await perform(.closeSession(sessionID: session.id)) != nil else { return }
        server.forgetConversation(session.id)
        await reloadSessions()
    }
    func reorderSessions(to ids: [SessionID]) { sessionOrder = ids }
    func isRunning(_ session: Session) -> Bool { existingTranscript(for: session.id)?.isRunning == true || session.state == .running }
    func existingTranscript(for id: SessionID) -> TranscriptModel? { server.existingConversation(id) }
    func prepareTranscript(for id: SessionID) { _ = server.conversation(id: id, app: app) }
    func panePosition(pane: String, session: SessionID) -> TranscriptPaneState? { panePositions[.init(pane: pane, session: session)] }
    func rememberPanePosition(_ state: TranscriptPaneState, pane: String, session: SessionID) { panePositions[.init(pane: pane, session: session)] = state }
    func readNote() async throws -> String {
        if case .text(let text) = try await read(.workspace(workspaceID: workspace.id, action: .notes)) { return text }
        return ""
    }
    func writeNote(_ body: String) async throws { _ = try await read(.workspace(workspaceID: workspace.id, action: .saveNotes(body))) }

    private func perform(_ operation: ServerOperation) async -> ServerResult? {
        guard server.endpoint == endpoint else { server.error = "Reconnect to this workspace's server."; return nil }
        return await server.perform(operation)
    }

    private func read(_ operation: ServerOperation) async throws -> ServerResult {
        guard server.endpoint == endpoint else { throw ServerFailure("Reconnect to this workspace's server.") }
        return try await server.read(operation)
    }
    var changedFiles: [ChangedFile] { server.review.files }
    var reviewFiles: [ChangedFile] { server.review.reviewFiles }
    var selectedFilePath: String? {
        get { server.review.selectedPath }
        set { server.review.selectedPath = newValue }
    }
    var changesError: String? { server.review.error }
    var isLoadingChanges: Bool { !server.review.hasReadFiles && server.review.error == nil }
    var hasReadChanges: Bool { server.review.hasReadFiles || server.review.error != nil }
    var diffScope: DiffScope { server.review.scope == .branch ? .all : .uncommitted }
    var viewedSummary: String? { nil }
    var supportsLocalFileActions: Bool { false }
    var supportsFileRevert: Bool { false }
    var supportsViewedMarks: Bool { false }
    var fileTree: [String: [FileTreeNode]] {
        let paths = server.review.allFiles
        if paths != indexedPaths { indexedTree = FileTreeNode.index(paths); indexedPaths = paths }
        return indexedTree
    }
    func isViewed(_ file: ChangedFile) -> Bool { false }
    func setViewed(_ value: Bool, file: ChangedFile) async {}
    func clearViewedFiles() async {}
    func reloadChanges() async {
        do {
            if case .changes(let files) = try await read(.changes(workspaceID: workspace.id, scope: server.review.scope)),
               server.selectedWorkspace?.id == workspace.id { server.review.files = files }
        } catch {
            if !Task.isCancelled, server.selectedWorkspace?.id == workspace.id { server.review.error = error.localizedDescription }
        }
    }
    func loadFileTree() async {
        do {
            if case .files(let paths) = try await read(.workspace(workspaceID: workspace.id, action: .files)),
               server.selectedWorkspace?.id == workspace.id { server.review.allFiles = paths; hasReadFileTree = true }
        } catch {
            if !Task.isCancelled, server.selectedWorkspace?.id == workspace.id { server.review.error = error.localizedDescription }
        }
    }
    func setShowsAllFiles(_ all: Bool) { FileReview.setShowsAllFiles(all, in: self) }
    func showReview(path: String) {
        guard server.selectedWorkspace?.id == workspace.id else { return }
        server.review.showsFile = !changedFiles.contains { $0.path == path }
        server.review.selectedPath = path
        FileReview.open(path: path, in: self)
    }
    func showTerminal(folder: String) {}
    func showPage(path: String, axis: SplitAxis?) {}
    func revertFile(_ file: ChangedFile) async -> String? { "Remote file revert is not available yet." }
    func patch(for file: ChangedFile) async -> String {
        let key = server.review.scope.rawValue + "/" + file.path
        if let held = patchCache[key], held.revision == file.contentRevision { return held.patch }
        do {
            if case .reviewPatch(let value) = try await read(.reviewPatch(workspaceID: workspace.id, path: file.path,
                scope: server.review.scope, knownRevision: patchCache[key]?.revision)) {
                if let patch = value.patch {
                    patchBytes -= patchCache[key]?.patch.utf8.count ?? 0
                    patchCache[key] = (value.revision, patch); patchBytes += patch.utf8.count
                    patchOrder.removeAll { $0 == key }; patchOrder.append(key)
                    while patchBytes > 16 * 1_024 * 1_024 || patchOrder.count > 64 {
                        patchBytes -= patchCache.removeValue(forKey: patchOrder.removeFirst())?.patch.utf8.count ?? 0
                    }
                    return patch
                }
                return patchCache[key]?.patch ?? ""
            }
        } catch { if !Task.isCancelled { server.error = error.localizedDescription } }
        return ""
    }
    private func presentationKey(_ file: ChangedFile, ignoringWhitespace: Bool) -> DiffPresentationCache.Key {
        DiffPresentationCache.Key(worktree: workspace.path, base: workspace.baseBranch + (file.contentRevision ?? ""),
            file: file, scope: diffScope, ignoresWhitespace: ignoringWhitespace)
    }
    func heldDiff(for file: ChangedFile, ignoringWhitespace: Bool) -> DiffPresentation? {
        presentations.presentation(for: presentationKey(file, ignoringWhitespace: ignoringWhitespace))
    }
    func holdDiff(_ presentation: DiffPresentation, for file: ChangedFile, ignoringWhitespace: Bool) {
        let key = server.review.scope.rawValue + "/" + file.path
        guard let size = patchCache[key]?.patch.utf8.count, size <= 256 * 1_024 else { return }
        presentations.store(presentation, for: presentationKey(file, ignoringWhitespace: ignoringWhitespace))
    }
    func forgetHeldDiff(for path: String) {
        heldContents[path] = nil; presentations.forget(file: path)
        for scope in ServerDiffScope.allCases {
            let key = scope.rawValue + "/" + path
            patchBytes -= patchCache.removeValue(forKey: key)?.patch.utf8.count ?? 0
            patchOrder.removeAll { $0 == key }
        }
    }
    func contents(of path: String) -> String? { heldContents[path] }
    func readContents(of path: String) async -> String? {
        do {
            if case .file(let file) = try await read(.file(workspaceID: workspace.id, path: path)) {
                heldContents[path] = file.text
                return file.text
            }
        } catch { /* Deleted and binary files have no text context to expand. */ }
        return nil
    }
    func addReviewComment(filePath: String, selection: ReviewSelection, anchor: ReviewCommentAnchor, body: String) async {}
    func editReviewComment(id: ReviewCommentID, body: String) async {}
    func removeReviewComment(id: ReviewCommentID) async {}
}
