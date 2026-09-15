import Foundation
import Observation
import BloomCore
import BloomClient

/// The Mac retains pane selection and its native DiffView presentation cache. Shared review state
/// owns snapshots and file reads; this adapter never fetches a patch behind DiffView's back.
@MainActor
@Observable
final class ServerReviewModel {
    var files: [ChangedFile] { store?.changes ?? [] }
    var reviewFiles: [ChangedFile] { store?.orderedChanges ?? [] }
    var allFiles: [String] { store?.paths ?? [] }
    var hasReadFiles: Bool { store?.hasLoaded ?? false }
    var contentGeneration: Int { store?.contentGeneration ?? 0 }
    var error: String? { contentError ?? store?.error }
    var isLoading: Bool { isLoadingContent || (store?.isLoading ?? false) }
    var selectedPath: String? { didSet { if oldValue != selectedPath { invalidateContent() } } }
    var scope = ServerDiffScope.branch {
        didSet {
            if oldValue != scope { store?.setScope(scope == .branch ? .branch : .uncommitted); invalidateContent() }
        }
    }
    var showsFile = false { didSet { if oldValue != showsFile { invalidateContent() } } }
    var showsAllFiles = false
    var fileFilter = ""
    var patch = "" { didSet { if oldValue != patch { lines = DiffParser.parse(patch).flatMap { $0.hunks.flatMap(\.lines) } } } }
    var lines: [DiffLine] = []
    var fileText = ""
    var fileRevision = ""
    private var store: WorkspaceReviewStore?
    private var contentError: String?
    private var isLoadingContent = false
    private var generation = 0
    private var needsContent = true

    func reset() {
        let previous = store
        store = nil
        previous?.cancel()
        selectedPath = nil
        invalidateContent()
    }

    private func invalidateContent() {
        generation += 1
        store?.cancel()
        patch = ""; fileText = ""; fileRevision = ""; contentError = nil
        needsContent = true; isLoadingContent = selectedPath != nil && showsFile
    }

    private func state(workspaceID: WorkspaceID) -> WorkspaceReviewStore {
        if let store, store.workspaceID == workspaceID { return store }
        reset()
        let state = WorkspaceReviewStore(workspaceID: workspaceID, scope: scope == .branch ? .branch : .uncommitted)
        store = state
        state.changed = { [weak self, weak state] in
            guard let self, let state, self.store === state, state.hasLoaded else { return }
            if !self.showsFile, let selected = self.selectedPath, !state.changes.contains(where: { $0.path == selected }) {
                self.selectedPath = nil
            }
        }
        return state
    }

    func refresh(client: ServerClient, workspaceID: WorkspaceID, refreshFiles: Bool) async {
        await refresh(using: ServerWorkspaceReviewReader(client: client), workspaceID: workspaceID, refreshFiles: refreshFiles)
    }

    func refresh(using source: any WorkspaceReviewReading, workspaceID: WorkspaceID, refreshFiles: Bool, wait: Bool = true) async {
        let state = state(workspaceID: workspaceID)
        let observed = generation, previousContentGeneration = state.contentGeneration
        await state.refresh(using: source, refreshFiles: showsAllFiles && (refreshFiles || !state.hasLoadedFiles), wait: wait && !needsContent)
        guard generation == observed, store === state, !Task.isCancelled else { return }
        if previousContentGeneration != state.contentGeneration { needsContent = true }
        guard showsFile else { needsContent = false; isLoadingContent = false; return }
        guard let selectedPath, needsContent else { return }
        isLoadingContent = fileText.isEmpty
        defer { if generation == observed { isLoadingContent = false } }
        do {
            let file = try await state.readFile(path: selectedPath, using: source)
            guard generation == observed, store === state, !Task.isCancelled else { return }
            fileText = file.text; fileRevision = file.revision; contentError = nil; needsContent = false
        } catch {
            if generation == observed, !Task.isCancelled { contentError = error.localizedDescription }
        }
    }

    func loadFileTree(using source: any WorkspaceReviewReading, workspaceID: WorkspaceID) async -> Bool {
        let state = state(workspaceID: workspaceID)
        await state.refreshPaths(using: source)
        return store === state && state.hasLoadedFiles
    }
}
