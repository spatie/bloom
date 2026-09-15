import Foundation

/// Whether the centre column draws its tab strip.
///
/// **Safari's rule, with one exception for a split.** A window with one tab shows no tab bar,
/// because a lone tab repeats the title already above it and costs a row of height to say so. The
/// strip used to stay up regardless, and the only reason was the `+` at its end: a control nobody
/// can reach is not a control. The `+` lives in the title bar now, so that reason is gone.
///
/// **A split keeps the strip up, even on a single tab.** The strip is one row for the whole
/// workspace rather than one per pane, and a tab that has been split is an arrangement: its entry
/// is what names it, renames it, closes it and is dragged to rearrange it, and a tab dropped onto a
/// pane comes from here. Hiding that the moment the second tab was absorbed into a pane would take
/// the arrangement's only handle away at exactly the point it became something worth handling. So
/// the strip goes only when there is one tab showing one pane, which is the case where it says
/// nothing the title bar does not.
///
/// **A rename in progress keeps it up too.** Rename Tab in the File menu opens its field on the
/// strip, and a field on a row that is not drawn is a menu item that does nothing.
public enum TabStripVisibility {
    /// - Parameters:
    ///   - tabCount: the entries the strip would draw.
    ///   - paneCount: how many panes the selected tab is split into, one for a tab nobody split.
    ///   - isRenaming: whether a tab's name field is open.
    public static func isShown(tabCount: Int, paneCount: Int, isRenaming: Bool = false) -> Bool {
        if isRenaming { return tabCount > 0 }
        return tabCount > 1 || (tabCount == 1 && paneCount > 1)
    }
}
