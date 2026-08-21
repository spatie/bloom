import SwiftUI
import BloomCore

/// The contextual menu a pane of the centre column offers on right click.
///
/// Its own view, and it knows nothing about workspaces, stores or sessions: it is handed two
/// closures and reports which item was picked. That is what lets the menu be built and looked at
/// on its own, which is the only way a submenu can be photographed at all. See `MenuProbe`.
///
/// The two directions are submenus rather than plain items. Splitting used to show this pane's own
/// tab in both halves, which is what splitting means in an editor, where a second view of one file
/// is the point. Here it almost never is: a second copy of a transcript scrolls itself, and the
/// reason to split this column is to put a shell or a page beside the conversation. So the
/// direction and what goes in it are one gesture now, and the duplicate keeps the keystroke it
/// always had, Cmd+\ in the View menu. See `BloomCommands`.
///
/// No key equivalents on any of these. A context menu is neither the menu bar nor the view
/// hierarchy, and a shortcut written on an item in one is drawn and never fired, which is the trap
/// `SessionTabsView.shortcuts` exists to get out of. Six new bindings would also have to stay clear
/// of the terminal's Cmd+D and Shift+Cmd+D, which split shells and are what a user of iTerm or
/// Ghostty already has in their hands.
struct CenterPaneMenu: View {
    /// Whether the column is split at all. A single pane has nothing to close back to.
    var isSplit: Bool
    var split: @MainActor (SplitAxis, PaneKind) -> Void
    var close: @MainActor () -> Void

    var body: some View {
        submenu("Split Right", symbol: PaneSymbol.splitRight, axis: .horizontal)
        submenu("Split Down", symbol: PaneSymbol.splitDown, axis: .vertical)
        if isSplit {
            Divider()
            Button("Close Pane", systemImage: PaneSymbol.closePane, action: close)
        }
    }

    /// One direction, and the three things that can be put in the half that opens.
    ///
    /// No heading over them, for the same reason the other menus lost theirs: the item this hangs
    /// off already says what the list is.
    private func submenu(_ title: String, symbol: String, axis: SplitAxis) -> some View {
        Menu(title, systemImage: symbol) {
            PaneKindItems { split(axis, $0) }
        }
    }
}

/// The three kinds, as menu items.
///
/// Its own view so that it can be built and photographed on its own, which is the only way a
/// submenu's contents can be got at: AppKit shows one menu at a time, so a submenu cannot be
/// opened beside the item it hangs off from inside the process. See `MenuProbe`.
///
/// The nouns and the glyphs come from `PaneKind`, which is where the strip's `+` menu takes its
/// own from, so the two lists cannot end up calling the same thing by two names.
struct PaneKindItems: View {
    var pick: @MainActor (PaneKind) -> Void

    var body: some View {
        ForEach(PaneKind.allCases) { kind in
            Button(kind.title, systemImage: kind.symbol) { pick(kind) }
        }
    }
}
