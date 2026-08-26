import SwiftUI
import BloomCore

/// The one way a terminal is opened on a folder of the worktree.
///
/// `FileReview` next door is the same shape and exists for the same reason: two trees in the
/// inspector offer this, and neither of them should have to know how a tab is made or where the
/// centre column puts one. It goes through `NewPane.open`, which is the door the strip's `+`, the
/// pane menus and `pane_open` all use, so a shell opened from a folder row is exactly the tab a
/// terminal normally is.
@MainActor
enum FolderTerminalTab {
    /// Opens a terminal tab in `folder`, named after it, and brings it forward.
    ///
    /// Nothing happens if the folder has gone between the right click and the click, which is the
    /// same answer `FolderTerminal.canOpen` gave the menu when it decided whether to draw the item
    /// at all.
    static func open(folder: String, in model: WorkspaceModel) {
        guard let target = target(folder: folder, in: model) else { return }
        NewPane.open(
            .terminal, in: model, title: target.title, directory: target.directory
        ) { content in
            WorkspaceTabsStore.shared.reveal(content, in: model)
        }
    }

    /// The tab a folder would make in this workspace, numbered against the terminals it already
    /// has, or nothing if the folder is empty or not on disk.
    ///
    /// Asked by `PaneDuplicate` as well, so that duplicating a shell standing in `resources/css`
    /// opens another one there rather than back at the worktree root.
    static func target(folder: String, in model: WorkspaceModel) -> FolderTerminal.Target? {
        let taken = CenterTabStore.shared.tabs(for: model.workspace.id)
            .filter { $0.kind == .terminal }
            .map(\.title)
        return FolderTerminal.target(folder: folder, taken: taken)
    }
}
