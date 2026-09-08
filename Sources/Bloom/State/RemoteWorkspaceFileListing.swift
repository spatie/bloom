import Foundation
import Observation
import BloomCore

@MainActor
@Observable
final class RemoteWorkspaceFileListing: WorkspaceFileListing {
    let workspace: Workspace
    private let server: ServerWindowModel
    @ObservationIgnored private var indexedPaths: [String] = []
    @ObservationIgnored private var indexedTree: [String: [FileTreeNode]] = [:]
    private(set) var hasReadFileTree = false

    init(workspace: Workspace, server: ServerWindowModel) { self.workspace = workspace; self.server = server }
    var changedFiles: [ChangedFile] { server.review.files }
    var selectedFilePath: String? {
        get { server.review.selectedPath }
        set { server.review.selectedPath = newValue }
    }
    var changesError: String? { server.review.error }
    var isLoadingChanges: Bool { !server.review.hasReadFiles }
    var hasReadChanges: Bool { server.review.hasReadFiles }
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
            if case .changes(let files) = try await server.read(.changes(workspaceID: workspace.id, scope: server.review.scope)),
               server.selectedWorkspace?.id == workspace.id { server.review.files = files }
        } catch { server.review.error = error.localizedDescription }
    }
    func loadFileTree() async {
        do {
            if case .files(let paths) = try await server.read(.workspace(workspaceID: workspace.id, action: .files)),
               server.selectedWorkspace?.id == workspace.id { server.review.allFiles = paths; hasReadFileTree = true }
        } catch { server.review.error = error.localizedDescription }
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
}
