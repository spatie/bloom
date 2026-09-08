import Foundation
import Observation
import BloomCore

@MainActor
@Observable
final class RemoteWorkspaceFileListing: WorkspaceFileReview {
    let workspace: Workspace
    private let server: ServerWindowModel
    private let endpoint: ServerEndpoint?
    @ObservationIgnored private var indexedPaths: [String] = []
    @ObservationIgnored private var indexedTree: [String: [FileTreeNode]] = [:]
    private(set) var hasReadFileTree = false
    var reviewDrafts: [String: ReviewDraft] = [:]
    var reviewEdits: Set<ReviewCommentID> = []
    let reviewText = ReviewTextHost()
    private var heldContents: [String: String] = [:]
    var reviewComments: [ReviewComment] { [] }
    var supportsReviewComments: Bool { false }
    var changesGeneration: Int { server.review.contentGeneration }
    var repo: Repo? { server.catalogue?.repositories.first { $0.id == workspace.repoID } }
    let fileEdits: FileEditSession

    init(workspace: Workspace, server: ServerWindowModel) {
        self.workspace = workspace
        self.server = server
        endpoint = server.endpoint
        fileEdits = server.fileEdits(for: workspace)
    }

    private func read(_ operation: ServerOperation) async throws -> ServerResult {
        guard server.endpoint == endpoint else { throw ServerFailure("Reconnect to this workspace's server.") }
        return try await server.read(operation)
    }
    var changedFiles: [ChangedFile] { server.review.files }
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
    func showReview(path: String) {
        guard server.selectedWorkspace?.id == workspace.id else { return }
        server.review.showsFile = !changedFiles.contains { $0.path == path }
        server.review.selectedPath = path
        server.activePane = "review"
    }
    func showTerminal(folder: String) {}
    func showPage(path: String, axis: SplitAxis?) {}
    func revertFile(_ file: ChangedFile) async -> String? { "Remote file revert is not available yet." }
    func patch(for file: ChangedFile) async -> String {
        do {
            if case .patch(let patch) = try await read(.patch(workspaceID: workspace.id, path: file.path, scope: server.review.scope)) { return patch }
        } catch { if !Task.isCancelled { server.error = error.localizedDescription } }
        return ""
    }
    func heldDiff(for file: ChangedFile, ignoringWhitespace: Bool) -> DiffPresentation? { nil }
    func holdDiff(_ presentation: DiffPresentation, for file: ChangedFile, ignoringWhitespace: Bool) {}
    func forgetHeldDiff(for path: String) { heldContents[path] = nil }
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
