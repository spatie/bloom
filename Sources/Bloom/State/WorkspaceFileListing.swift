import Foundation
import BloomCore

/// Data and actions used by the inspector's existing lists, independent of execution host.
@MainActor
protocol WorkspaceFileListing: AnyObject {
    var workspace: Workspace { get }
    var changedFiles: [ChangedFile] { get }
    var selectedFilePath: String? { get set }
    var changesError: String? { get }
    var isLoadingChanges: Bool { get }
    var hasReadChanges: Bool { get }
    var diffScope: DiffScope { get }
    var viewedSummary: String? { get }
    var fileTree: [String: [FileTreeNode]] { get }
    var hasReadFileTree: Bool { get }
    var supportsLocalFileActions: Bool { get }
    var supportsFileRevert: Bool { get }
    var supportsViewedMarks: Bool { get }
    func isViewed(_ file: ChangedFile) -> Bool
    func setViewed(_ value: Bool, file: ChangedFile) async
    func clearViewedFiles() async
    func reloadChanges() async
    func loadFileTree() async
    func showReview(path: String)
    func setShowsAllFiles(_ all: Bool)
    func showTerminal(folder: String)
    func showPage(path: String, axis: SplitAxis?)
    func revertFile(_ file: ChangedFile) async -> String?
}

extension WorkspaceModel: WorkspaceFileListing {
    var supportsLocalFileActions: Bool { true }
    var supportsFileRevert: Bool { true }
    var supportsViewedMarks: Bool { true }
    func reloadChanges() async { await refreshChanges() }
    func loadFileTree() async { await refreshFileTree() }
    func setShowsAllFiles(_ all: Bool) { FileReview.setShowsAllFiles(all, in: self) }
    func showReview(path: String) { FileReview.open(path: path, in: self) }
    func showTerminal(folder: String) { FolderTerminalTab.open(folder: folder, in: self) }
    func showPage(path: String, axis: SplitAxis?) {
        if let axis { BrowserTab.splitFile(path, in: self, axis: axis) } else { BrowserTab.openFile(path, in: self) }
    }
    func revertFile(_ file: ChangedFile) async -> String? {
        let absolute = (workspace.path as NSString).appendingPathComponent(file.path)
        FileEditSession.shared.discard(path: absolute)
        let failure = await FileRevert.revert(file: file, in: workspace)
        forgetHeldDiff(for: file.path)
        await refreshChanges()
        return failure
    }
}
