import Foundation

/// Whether the centre column draws its tab strip.
///
/// **Safari's rule.** A window with one tab shows no tab bar, because a lone tab repeats the title
/// already above it and costs a row of height to say so. The strip used to stay up regardless, and
/// the only reason was the `+` at its end: a control nobody can reach is not a control. The `+`
/// lives in the title bar now, so that reason is gone.
///
/// **A split does not change that.** It used to: a single tab split into panes kept the strip, on
/// the argument that its entry was the arrangement's handle. What the owner saw was a strip holding
/// one tab named "Chat" above a chat and a browser side by side, which is the lone tab Safari's
/// rule exists to hide, and the panes already carry their own close and split menus.
///
/// **A rename in progress keeps it up.** Rename Tab in the File menu opens its field on the strip,
/// and a field on a row that is not drawn is a menu item that does nothing.
public enum TabStripVisibility {
    /// - Parameters:
    ///   - tabCount: the entries the strip would draw.
    ///   - isRenaming: whether a tab's name field is open.
    public static func isShown(tabCount: Int, isRenaming: Bool = false) -> Bool {
        if isRenaming { return tabCount > 0 }
        return tabCount > 1
    }
}
