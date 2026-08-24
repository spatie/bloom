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
    static func open(path: String, in model: WorkspaceModel) {
        let tab = CenterTabStore.shared.showReview(path: path, workspaceID: model.workspace.id)
        // `reveal` brings the tab holding the review forward and takes nothing off a pane, so the
        // rule above is kept by the door rather than by a guard here. A review already on screen
        // is already on screen, whichever pane of the tab in front is showing it.
        WorkspaceTabsStore.shared.reveal(.tool(tab.id), in: model)
    }

    /// Opens the review on whatever the reader was last looking at, which is the selected changed
    /// file, and failing that the first one. Used by the `+` menu and by the keyboard, where no
    /// file has been named.
    static func open(in model: WorkspaceModel) {
        let remembered = CenterTabStore.shared.review(for: model.workspace.id)?.path
        let fallback = model.selectedFilePath ?? model.changedFiles.first?.path
        open(path: remembered.flatMap { $0.isEmpty ? nil : $0 } ?? fallback ?? "", in: model)
    }

    /// The same keystroke both ways: open the review, or, if the pane the reader is in is already
    /// showing it, put the conversation back. The tab stays open, because the keystroke is about
    /// what is in front of them rather than about what they are keeping.
    static func toggle(in model: WorkspaceModel) {
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: model) else { return open(in: model) }
        let pane = tabs.focusedPane(of: tab)

        if let review = CenterTabStore.shared.review(for: model.workspace.id),
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
    static func step(_ delta: Int, in model: WorkspaceModel) {
        let files = model.changedFiles
        guard !files.isEmpty else { return }

        let current = CenterTabStore.shared.review(for: model.workspace.id)?.path
        let index = files.firstIndex { $0.path == current }
        let next = index.map { ($0 + delta + files.count) % files.count } ?? 0

        model.selectedFilePath = files[next].path
        open(path: files[next].path, in: model)
    }
}
