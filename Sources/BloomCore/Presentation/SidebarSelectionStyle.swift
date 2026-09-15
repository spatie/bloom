import Foundation

/// How a row in the sidebar says it is the selection, and the one rule over it.
///
/// **The bug: switch away from Bloom and back, and the selected workspace turns solid blue.** The
/// pane is a `List` with `.listStyle(.sidebar)`, which is an `NSOutlineView`, and for a while the
/// table drew its own selection. AppKit's rule for that drawing is the accent colour whenever the
/// table is first responder in the key window, and a quiet grey otherwise. Bloom's accent is its
/// house blue, because `NSAccentColorName` points at the `AccentColor` set. So while the keyboard
/// was somewhere else the row sat on the grey the owner had asked for, and the moment the window
/// became key again with the table holding the keyboard, AppKit re-emphasised the row view and
/// painted the blue under ink that had not been told to invert: dark text and a diff stat nobody
/// could read on `#197593`.
///
/// The owner had already chosen the grey, comparing the pane with Finder's sidebar, where the
/// selected item keeps its ordinary ink on a quiet fill whatever has the keyboard. So the fill is
/// the same in every state, and the one thing that changes is an edge, drawn only while the arrow
/// keys really do move this list. The edge is what a keyboard user reads to know where the next
/// arrow lands, and it carries no accent, so it cannot reproduce the report.
public enum SidebarSelectionStyle: Sendable, Equatable {
    /// Not the selected row. Nothing is drawn, so the list's own hover wash still shows.
    case unselected
    /// Selected, and the keyboard is elsewhere, or this window is not the one being used.
    case resting
    /// Selected, in the key window, with the list holding the keyboard.
    case keyboard

    /// - Parameters:
    ///   - isSelected: whether this row is what the list itself thinks is selected.
    ///   - listHasKeyboard: whether the sidebar's table is the window's first responder.
    ///   - windowIsKey: whether that window is the key window. A table can stay first responder in
    ///     a window that is not key, which is the state the owner switched back from, and the
    ///     arrow keys move nothing there.
    public static func resolve(
        isSelected: Bool, listHasKeyboard: Bool, windowIsKey: Bool
    ) -> SidebarSelectionStyle {
        guard isSelected else { return .unselected }
        return listHasKeyboard && windowIsKey ? .keyboard : .resting
    }

    /// Whether the quiet fill is drawn. The same fill for both selected styles, by design.
    public var drawsFill: Bool { self != .unselected }

    /// Whether the keyboard edge is drawn over the fill.
    public var drawsKeyboardEdge: Bool { self == .keyboard }
}
