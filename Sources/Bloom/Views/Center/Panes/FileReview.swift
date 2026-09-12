import SwiftUI
import BloomCore

/// The one way a file gets onto the screen.
///
/// Every route into a file goes through here: a row in the changed file list, a row in the
/// worktree tree, the `+` menu, the keyboard. They all mean the same thing, so they all do the
/// same thing, and the inspector does not have to know how the centre column is arranged in order
/// to open something in it.
///
/// It deliberately does not steal the review into the pane the reader is typing in. With the
/// column split, the point of this feature is a diff on one side and the conversation on the
/// other; clicking a filename must not collapse that back into one thing.
@MainActor
enum FileReview {
    /// Opens the workspace's review on a file, or points the open one at it.
    static func open(path: String, in model: any WorkspacePaneModel, focusing: Bool = false) {
        let location = CodeLocation.parse(path)
        if location.path != path { open(location: location, in: model); return }
        model.paneStores.sourceFile((model.workspace.path as NSString).appendingPathComponent(path)).diffRequest = nil
        model.paneStores.sourceNavigation.visit(location, in: model)
        if model.changedFiles.contains(where: { $0.path == path }) { model.selectedFilePath = path }
        show(path: path, in: model, focusing: focusing)
        // A new shared review defaults to all changes, but unchanged files open on their own.
        if !model.changedFiles.contains(where: { $0.path == path }),
           let tab = model.paneStores.center.review(for: model.workspace.id) {
            model.paneStores.center.setShowsAllFiles(false, for: tab)
        }
    }

    static func open(location: CodeLocation, in model: any WorkspacePaneModel, recording: Bool = true) {
        var location = location
        location.path = location.displayPath(relativeTo: model.workspace.path)
        if recording { model.paneStores.sourceNavigation.visit(location, in: model) }
        let absolute = (location.path as NSString).isAbsolutePath ? location.path
            : (model.workspace.path as NSString).appendingPathComponent(location.path)
        model.paneStores.sourceFile(absolute).go(to: location)
        show(path: location.path, in: model, focusing: true)
        if let tab = model.paneStores.center.review(for: model.workspace.id) {
            model.paneStores.center.setShowsAllFiles(false, for: tab)
        }
        if model.changedFiles.contains(where: { $0.path == location.path }) { model.selectedFilePath = location.path }
    }

    static func activePath(in model: any WorkspacePaneModel) -> String? {
        let workspaceTabs = model.paneStores.tabs
        guard let selected = workspaceTabs.selectedTab(in: model) else { return nil }
        let layout = workspaceTabs.layout(of: selected)
        let panes = [layout.focus] + layout.panes.filter { $0 != layout.focus }
        let tabs = model.paneStores.center.tabs(for: model.workspace.id)
        for pane in panes {
            guard case let .tool(id) = workspaceTabs.content(of: pane, in: selected),
                  let tab = tabs.first(where: { $0.id == id && $0.kind == .review }) else { continue }
            let path = tab.showsAllFiles && !tab.isPinnedToPath ? model.selectedFilePath ?? tab.path : tab.path
            if !path.isEmpty { return CodeLocation(path: path).displayPath(relativeTo: model.workspace.path) }
        }
        return nil
    }

    static func openFromDiff(_ target: CodeLocation, in model: any WorkspacePaneModel, newTab: Bool) async {
        var location = target
        location.path = location.displayPath(relativeTo: model.workspace.path)
        if !newTab, let file = model.reviewFiles.first(where: { $0.path == location.path }) {
            let patch = await model.patch(for: file)
            guard !Task.isCancelled else { return }
            if let diff = DiffDocument.parse(patch: patch, path: file.path), DiffDocument.contains(location, in: diff) {
                let absolute = (model.workspace.path as NSString).appendingPathComponent(location.path)
                let state = model.paneStores.sourceFile(absolute)
                state.request = nil
                state.prefersEditing = false
                state.diffLine = location.line
                state.diffRequest = location
                state.diffRevision &+= 1
                model.paneStores.sourceNavigation.visit(location, in: model)
                model.selectedFilePath = location.path
                show(path: location.path, in: model, focusing: true)
                return
            }
        }
        openInNewTab(path: "\(location.path):\(location.line):\(location.column)", in: model)
    }

    /// The one door, with the one thing the two callers disagree about.
    ///
    /// `focusing` is false for a filename clicked in the inspector, because the reader's attention
    /// is over there and moving the pane focus under them would take the keyboard off the list
    /// they are walking. It is true for the routes that name no file, which are the `+` menu and
    /// the keyboard: those are somebody asking to BE in the review, and a request that lands on a
    /// pane nobody is standing in looks exactly like a menu item that does nothing.
    private static func show(path: String, in model: any WorkspacePaneModel, focusing: Bool) {
        let tab = model.paneStores.center.showReview(path: path, workspaceID: model.workspace.id)
        // `reveal` brings the tab holding the review forward and takes nothing off a pane, so the
        // rule above is kept by the door rather than by a guard here. A review already on screen
        // is already on screen, whichever pane of the tab in front is showing it.
        model.paneStores.tabs.reveal(.tool(tab.id), in: model, focusing: focusing)
    }

    /// Opens a file in a tab that stays on it, which is what a double click on a file pill and
    /// Open in New Tab from its menu both mean.
    ///
    /// The other door, above, points the workspace's one review tab at a file, and that is still
    /// what a single click does. This one is the deliberate second gesture: the tab it opens is
    /// never the one `showReview` repoints, so a reading you set aside survives the next filename
    /// you click. See `CenterTab.isPinnedToPath`.
    static func openInNewTab(path: String, in model: any WorkspacePaneModel) {
        let location = CodeLocation.parse(path)
        model.paneStores.sourceNavigation.visit(location, in: model)
        if location.path != path {
            let absolute = (location.path as NSString).isAbsolutePath ? location.path
                : (model.workspace.path as NSString).appendingPathComponent(location.path)
            model.paneStores.sourceFile(absolute).go(to: location)
        }
        let tab = model.paneStores.center.openPinnedReview(path: location.path, workspaceID: model.workspace.id)
        model.paneStores.tabs.reveal(.tool(tab.id), in: model)
    }

    /// Opens the review on whatever the reader was last looking at, which is the selected changed
    /// file, and failing that the first one. Used by the `+` menu and by the keyboard, where no
    /// file has been named.
    ///
    /// An empty path is a perfectly good answer and is deliberately not refused: a worktree with
    /// nothing in its diff still has a review tab to open, and what it draws is the sentence
    /// saying nothing differs from the base branch yet. Refusing here, or greying the menu row
    /// out, is what made this read as a control that did nothing.
    static func open(in model: any WorkspacePaneModel) {
        let remembered = currentPath(in: model)
        let fallback = model.selectedFilePath ?? model.reviewFiles.first?.path
        show(
            path: remembered.flatMap { $0.isEmpty ? nil : $0 } ?? fallback ?? "",
            in: model,
            focusing: true
        )
    }

    /// Scroll-follow is transient selection, not a navigation request. Keeping it out of
    /// the tab store avoids rebuilding every tool pane and writing defaults while scrolling.
    static func currentPath(in model: any WorkspacePaneModel) -> String? {
        let tab = model.paneStores.center.review(for: model.workspace.id)
        return tab?.showsAllFiles == true ? model.selectedFilePath ?? tab?.path : tab?.path
    }

    static func openAll(in model: any WorkspacePaneModel) {
        setShowsAllFiles(true, in: model)
    }

    /// Both mode controls use the review tab's state and remember the selected file.
    /// Returning to one file must not land on an empty review or silently choose another file.
    static func setShowsAllFiles(_ all: Bool, in model: any WorkspacePaneModel) {
        let store = model.paneStores.center
        let remembered = store.review(for: model.workspace.id)?.path
        let candidates = [model.selectedFilePath, remembered].compactMap { $0 }
        let path = candidates.first { candidate in
            model.changedFiles.contains { $0.path == candidate }
        } ?? model.reviewFiles.first?.path ?? ""
        let tab = store.showReview(path: path, workspaceID: model.workspace.id)
        store.setShowsAllFiles(all, for: tab)
        model.paneStores.tabs.reveal(.tool(tab.id), in: model)
    }

    /// The same keystroke both ways: open the review, or, if the pane the reader is in is already
    /// showing it, put the conversation back. The tab stays open, because the keystroke is about
    /// what is in front of them rather than about what they are keeping.
    static func toggle(in model: any WorkspacePaneModel) {
        let tabs = model.paneStores.tabs
        guard let tab = tabs.selectedTab(in: model) else { return open(in: model) }
        let pane = tabs.focusedPane(of: tab)

        if let review = model.paneStores.center.review(for: model.workspace.id),
           tabs.content(of: pane, in: tab) == .tool(review.id) {
            guard let session = model.activeSession ?? model.sessions.first else { return }
            // In an unsplit review tab this is picking the conversation's tab, which is what the
            // keystroke means there. In a split it points this one pane back at the conversation
            // and leaves the other half of the arrangement alone.
            tabs.replace(pane: pane, of: tab, with: .chat(session.id), in: model)
            return
        }
        open(in: model)
    }

    /// Walks the changed files, which is what a review is for. Wraps, so holding the shortcut down
    /// goes round rather than stopping dead at the last file, and keeps the inspector's own
    /// selection in step so the list scrolls and highlights along with the diff.
    static func step(_ delta: Int, in model: any WorkspacePaneModel) {
        let files = model.reviewFiles
        guard !files.isEmpty else { return }

        let current = currentPath(in: model)
        let index = files.firstIndex { $0.path == current }
        let next = index.map { ($0 + delta + files.count) % files.count } ?? 0

        model.selectedFilePath = files[next].path
        open(path: files[next].path, in: model)
    }
}
