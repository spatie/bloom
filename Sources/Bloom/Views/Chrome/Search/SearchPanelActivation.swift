import AppKit
import SwiftUI
import BloomCore

/// What Return does to the highlighted row.
///
/// **Every one of these is a route the app already has.** A workspace goes through the selection,
/// an archived one through `openArchived`, a transcript hit through `AppModel.open`, which already
/// picks the session and scrolls to the row, and a command through the real menu item. Nothing
/// here is a second implementation of anything, which is what keeps the panel a faster route
/// rather than a parallel app.
///
/// **The panel closes before the row is opened.** A menu item is validated against the responder
/// chain, and the panel's field is first responder while it is up, so an item pressed from an open
/// panel would be validated against a text field rather than against the window it is meant to act
/// on. Closing first is also what makes the transition read as one movement rather than as a card
/// that lingers over the thing it just opened.
@MainActor
enum SearchPanelActivation {
    static func open(
        _ row: SearchPanelRow, panel: SearchPanelModel, app: AppModel
    ) {
        let mode = panel.field.mode
        panel.close(app: app)

        switch row {
        case .workspace(let hit):
            open(hit, app: app)

        case .transcript(let hit):
            // The best match rather than the workspace, so Return lands on the sentence that was
            // drawn under the row. `AppModel.open` carries the session and the sequence number.
            guard let match = hit.result.best else { return }
            Task { await app.open(match) }

        case .command(let hit):
            run(hit.item.action, mode: mode, panel: panel, app: app)
        }
    }

    private static func open(_ hit: SearchPanelWorkspaceHit, app: AppModel) {
        if hit.isArchived {
            // The reader, which is the same split Home's rows make: an archived workspace has no
            // worktree, so it opens for reading rather than for working in.
            app.openArchived(hit.workspace)
        } else {
            app.selection = .workspace(hit.workspace.id)
        }
    }

    /// Runs a command row.
    ///
    /// In an action list the row is aimed at the workspace that was pushed into, which is not
    /// necessarily the one the Workspace menu is about: the menu acts on the selection or on the
    /// focused row, and the panel can be pointed at neither. So the action list goes through
    /// `SearchPanelWorkspaceCommands`, which takes the workspace as an argument. Everywhere else
    /// the menu bar's own item is the one pressed.
    private static func run(
        _ action: MenuBarAction, mode: SearchPanelMode, panel: SearchPanelModel, app: AppModel
    ) {
        if let id = mode.workspaceID,
           let workspace = app.workspaces.first(where: { $0.id == id })
               ?? panel.archived.first(where: { $0.id == id }),
           let workspaceAction = SearchPanelActions.workspaceAction(for: action) {
            SearchPanelWorkspaceCommands.perform(workspaceAction, on: workspace, app: app)
            return
        }

        // On the next turn of the run loop, because the panel is closing on this one and the item
        // is validated against whatever is first responder when it fires.
        DispatchQueue.main.async {
            MainMenuActions.perform(action)
        }
    }
}

/// One workspace's own menu, performed against that workspace rather than against whatever the
/// Workspace menu happens to be about.
///
/// It is the same work `WorkspaceMenuItems` does on a right click, reached the same way: `Reveal`,
/// `Clipboard` and the three writes on `AppModel`. Written out here rather than shared with that
/// view because a `View`'s buttons are closures inside a `body` and there is nothing to call.
@MainActor
enum SearchPanelWorkspaceCommands {
    /// Switched over the whole enum, so an item added to `WorkspaceMenuAction` has to be answered
    /// here or the build fails.
    static func perform(_ action: WorkspaceMenuAction, on workspace: Workspace, app: AppModel) {
        switch action {
        case .openInEditor:
            Reveal.inEditor(workspace.path, repo: workspace.repoID)
        case .revealInFinder:
            Reveal.inFinder(workspace.path)
        case .copyName:
            Clipboard.copy(workspace.name)
        case .copyBranchName:
            Clipboard.copy(workspace.branch)
        case .pin:
            Task { await app.togglePinned(workspace) }
        case .unreadMark:
            guard let mark = WorkspaceUnreadMark.action(for: workspace) else { return }
            Task { await app.setUnread(workspace, mark.unread) }
        case .rename:
            // The one item with no work of its own: the field belongs to whichever list is drawing
            // the row, so this is the post the menu bar's own Rename makes.
            NotificationCenter.default.post(
                name: .bloomRenameWorkspace, object: nil,
                userInfo: [Notification.bloomWorkspaceIDKey: workspace.id.rawValue]
            )
        case .archive:
            // Straight through, with no dialog of its own, exactly as the row's menu does it:
            // whether an archive needs confirming depends on what is uncommitted, what is running
            // and what GitHub says, and `AppModel.archive` is where all three come together.
            Task { await app.archive(workspace) }
        case .restore:
            Task { await app.restore(workspace) }
        case .colour:
            // A submenu of ten swatches rather than an action. `SearchPanelActions.order` does not
            // offer it, so this case is unreachable and is here because the switch is exhaustive
            // on purpose: an item added to the enum has to be classified.
            break
        }
    }
}
