import AppKit
import Observation
import BloomCore

/// Shared by reading and editing, with a separate entry for each worktree's absolute path.
@MainActor
@Observable
final class SourceEditorState {
    @ObservationIgnored var appliedRevision = -1
    var selection = NSRange(location: 0, length: 0)
    var scrollOrigin = NSPoint.zero
    var languageOverride: Language?
    var wraps = false
    var diffRow: String?
    var diffLine = 1
    var line = 1
    var column = 1
    var request: CodeLocation?
    var revision = 0
    @ObservationIgnored var navigationTask: Task<Void, Never>?
    var definitions: [CodeLocation] = []
    var message: String?
    var prefersEditing = false
    @ObservationIgnored weak var textView: CodeTextView?

    func go(to location: CodeLocation) {
        request = location
        revision &+= 1
    }

    func find() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }

    func selectedContext(path: String) -> String? {
        guard let view = textView, view.selectedRange().length > 0 else { return nil }
        let range = view.selectedRange()
        let start = CodeLocation.position(in: view.string, offset: range.location).line
        let end = CodeLocation.position(in: view.string, offset: NSMaxRange(range) - 1).line
        let text = (view.string as NSString).substring(with: range)
        let fence = String(repeating: "`", count: max(3, text.components(separatedBy: "\n").map { $0.prefix { $0 == "`" }.count + 1 }.max() ?? 3))
        return "\(path):\(start)-\(end)\n\(fence)\n\(text)\n\(fence)"
    }
}

@MainActor
@Observable
final class SourceNavigation {
    var histories: [WorkspaceID: SourceHistory] = [:]

    func visit(_ location: CodeLocation, in model: any WorkspacePaneModel) {
        var history = histories[model.workspace.id] ?? SourceHistory()
        if history.entries.indices.contains(history.index) {
            let current = history.entries[history.index].path
            let absolute = (current as NSString).isAbsolutePath ? current
                : (model.workspace.path as NSString).appendingPathComponent(current)
            let state = model.paneStores.sourceFile(absolute)
            history.updateCurrent(CodeLocation(path: current, line: state.line, column: state.column))
        }
        history.visit(location)
        histories[model.workspace.id] = history
    }

    func move(_ delta: Int, in model: any WorkspacePaneModel) {
        guard var history = histories[model.workspace.id] else { return }
        if history.entries.indices.contains(history.index) {
            let current = history.entries[history.index].path
            let absolute = (current as NSString).isAbsolutePath ? current : (model.workspace.path as NSString).appendingPathComponent(current)
            let state = model.paneStores.sourceFile(absolute)
            history.updateCurrent(CodeLocation(path: current, line: state.line, column: state.column))
        }
        guard let location = history.move(delta) else { return }
        histories[model.workspace.id] = history
        FileReview.open(location: location, in: model, recording: false)
    }
}
