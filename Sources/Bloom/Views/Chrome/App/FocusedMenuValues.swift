import SwiftUI
import BloomCore

/// What the menu bar reads off whatever currently holds the keyboard.
///
/// `BloomCommands` is one body, shared by every window and every screen the app has, so an item
/// that reads `AppModel` alone can only ever be about the sidebar's selection. That is the whole of
/// why the Workspace menu went dead on Home and in the Archive: a row was visibly highlighted in a
/// list and the menu had no way of hearing about it. `@FocusedValue` is the channel that carries
/// it, published by the list on screen and read by the item that acts on it, which is how Mail and
/// Finder key a menu to whichever list has focus.
///
/// `MainWindowFocus` is the same mechanism aimed at a different question, and it stays its own
/// file: which SCENE has the keyboard, rather than what inside it is selected.
extension FocusedValues {
    /// The workspace a list has highlighted, when that list is not the sidebar.
    ///
    /// Published by Home and by the Archive, which are the two screens whose selection is their own
    /// rather than the app's: writing `AppModel.selection` from either would navigate away from the
    /// list and open every row the arrow keys passed. `WorkspaceMenuSubject` in the core is the rule
    /// that decides which of the two answers, and its tests hold the precedence.
    @Entry var focusedWorkspaceRow: FocusedWorkspaceRow?

    /// What Save means right now, for the one window that has an explicit Save.
    ///
    /// Nil in every scene that has nothing to write, which is what greys the item out. Any view
    /// that binds Cmd+S should publish this as well: a view that keeps the key to itself is a key
    /// equivalent the menu bar cannot advertise, and unadvertised is undiscoverable.
    @Entry var saveAction: SaveAction?
}

/// A row a list has highlighted, carrying the workspace itself.
///
/// The value rather than the id, because Home lists archived workspaces and `AppModel` deliberately
/// does not hold those: it lists live ones so the sidebar can never show a worktree that is no
/// longer there. Home has already loaded the row it is drawing, so it is the only place that can
/// hand the menu something to act on without a database read.
struct FocusedWorkspaceRow: Equatable {
    var workspace: Workspace
    var isArchived: Bool

    /// The half of it the core's rule needs.
    var row: WorkspaceMenuSubject.FocusedRow {
        WorkspaceMenuSubject.FocusedRow(id: workspace.id, isArchived: isArchived)
    }
}

/// One window's Save, offered to the menu bar.
///
/// Identified by what it saves rather than by a closure alone, so two publishers cannot compare
/// equal and leave the item stuck reading the wrong window's state.
struct SaveAction: Equatable {
    /// What is being saved, for the item's own accessibility and for equality.
    var subject: String
    var isEnabled: Bool
    var perform: @MainActor () -> Void

    static func == (lhs: SaveAction, rhs: SaveAction) -> Bool {
        lhs.subject == rhs.subject && lhs.isEnabled == rhs.isEnabled
    }
}
