import Foundation
import BloomCore

/// File review, source navigation and opening local files from the inspector.
extension WorkspaceModel {
    func reviewContents(for file: ChangedFile) async -> String? {
        await Self.reviewContents(worktree: workspace.path, file: file, scope: diffScope)
    }

    func lookUpInDiff(at offset: Int, view: CodeTextView, lines: [DiffLine?], source: String,
                      path: String, references: Bool, automatic: Bool, newTab: Bool,
                      onOpen: @escaping (CodeLocation, Bool) -> Void) {
        SourceActions.lookupInDiff(at: offset, view: view, lines: lines, source: source, path: path,
                                   model: self, references: references, automatic: automatic,
                                   newTab: newTab, onOpen: onOpen)
    }

    func openFromDiff(_ location: CodeLocation, newTab: Bool) async {
        await FileReview.openFromDiff(location, in: self, newTab: newTab)
    }

    var canStepSourceHistory: (back: Bool, forward: Bool) {
        let history = SourceNavigation.shared.histories[workspace.id]
        return (history?.canGoBack == true, history?.canGoForward == true)
    }

    func stepSourceHistory(_ delta: Int) {
        SourceNavigation.shared.move(delta, in: self)
    }

    func openSource(at location: CodeLocation) {
        FileReview.open(location: location, in: self)
    }

    /// The file itself, on this Mac's disk. See `EditableFiles`.
    var editableFiles: any EditableFiles { DiskFiles() }

    func editorKey(for relativePath: String) -> String {
        (workspace.path as NSString).appendingPathComponent(relativePath)
    }

    func openTerminal(in folder: String) {
        FolderTerminalTab.open(folder: folder, in: self)
    }

    /// Nil: the file is on this Mac, and the menu offers the Finder and an editor instead.
    func gitHubURL(forFile relativePath: String?) -> URL? { nil }

    func openPage(path: String, splittingAxis: SplitAxis?) {
        if let axis = splittingAxis {
            BrowserTab.splitFile(path, in: self, axis: axis)
        } else {
            BrowserTab.openFile(path, in: self)
        }
    }
}
