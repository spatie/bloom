import Foundation
import Observation
import BloomCore

/// Selection and request generations keep a slow diff from the previous workspace off screen.
@MainActor
@Observable
final class ServerReviewModel {
    var files: [ChangedFile] = [] {
        didSet { reviewFiles = ChangedFileTree.orderedFiles(from: files) }
    }
    private(set) var reviewFiles: [ChangedFile] = []
    var selectedPath: String? {
        didSet { if oldValue != selectedPath { invalidateContent() } }
    }
    var scope = ServerDiffScope.branch {
        didSet { if oldValue != scope { files = []; hasReadFiles = false; invalidateContent() } }
    }
    var showsFile = false {
        didSet { if oldValue != showsFile { invalidateContent() } }
    }
    var patch = "" {
        didSet {
            if oldValue != patch { lines = DiffParser.parse(patch).flatMap { $0.hunks.flatMap(\.lines) } }
        }
    }
    var lines: [DiffLine] = []
    var fileText = ""
    var fileRevision = ""
    var showsAllFiles = false
    var allFiles: [String] = []
    var fileFilter = ""
    var error: String?
    var isLoading = false
    private var snapshotRevision: String?
    private var snapshotScope: ServerDiffScope?
    private var snapshotGeneration = 0
    private var workspaceID: WorkspaceID?
    private var generation = 0
    var contentGeneration: Int { snapshotGeneration }
    private var pendingSnapshot: Task<ServerReply, Error>?
    private var needsContent = true
    private(set) var hasReadFiles = false

    func reset() {
        snapshotRevision = nil
        workspaceID = nil
        files = []
        allFiles = []
        hasReadFiles = false
        selectedPath = nil
        invalidateContent()
    }

    private func invalidateContent() {
        pendingSnapshot?.cancel()
        generation += 1
        patch = ""
        fileText = ""
        fileRevision = ""
        error = nil
        needsContent = true
        isLoading = selectedPath != nil
    }

    func refresh(client: ServerClient, workspaceID: WorkspaceID, refreshFiles: Bool) async {
        if self.workspaceID != workspaceID {
            reset()
            self.workspaceID = workspaceID
        }
        let observed = generation
        do {
            if snapshotScope != scope { snapshotScope = scope; snapshotRevision = nil }
            let request = ServerRequest(.reviewSnapshot(workspaceID: workspaceID,
                scope: scope, knownRevision: snapshotRevision, wait: hasReadFiles && !needsContent))
            let pending = Task { try await client.request(request, timeout: .seconds(25)) }
            pendingSnapshot = pending
            defer { pendingSnapshot = nil }
            let snapshotReply = try await pending.value
            guard generation == observed else { return }
            if case .reviewSnapshot(let snapshot) = snapshotReply.result {
                if let changed = snapshot.files {
                    if snapshotRevision != snapshot.revision { snapshotGeneration += 1 }
                    snapshotRevision = snapshot.revision
                    needsContent = true
                    files = changed
                    hasReadFiles = true
                    error = nil
                    if showsAllFiles {
                        let listing = try await client.request(ServerRequest(.workspace(workspaceID: workspaceID, action: .files)), timeout: .seconds(25))
                        guard generation == observed else { return }
                        if case .files(let paths) = listing.result { allFiles = paths }
                    }
                    if !showsFile, let selectedPath, !changed.contains(where: { $0.path == selectedPath }) { self.selectedPath = nil }
                }
            }
            // Shared DiffView owns patch loading and caching. The review loop only publishes
            // revisions, so it cannot download the selected patch a second time.
            if !showsFile { needsContent = false; isLoading = false; return }
            guard generation == observed, let selectedPath, needsContent else { return }
            isLoading = patch.isEmpty && fileText.isEmpty
            let operation: ServerOperation = showsFile
                ? .file(workspaceID: workspaceID, path: selectedPath)
                : .patch(workspaceID: workspaceID, path: selectedPath, scope: scope)
            let reply = try await client.request(ServerRequest(operation), timeout: .seconds(25))
            guard generation == observed else { return }
            switch reply.result {
            case .patch(let text): patch = text
            case .file(let file): fileText = file.text; fileRevision = file.revision
            default: break
            }
            error = nil
            needsContent = false
            isLoading = false
        } catch {
            guard generation == observed, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}
