import Foundation

/// What Cmd+W closes in the centre column.
///
/// **The bug this is written from.** Cmd+W was Close Session, gated on the workspace having a
/// conversation rather than on what the user was looking at. So on a browser, a review or the
/// notes it closed a chat in some other pane, silently when that chat was idle, and four kinds of
/// tab could be opened from the keyboard while none of them could be closed. A Mac app closes what
/// is in front.
///
/// **Why there is no separate Close Session any more.** A conversation is a tab in the same strip
/// as a terminal and a page, so Close Tab already names it. Moving Close Session to Shift+Cmd+W,
/// which is the obvious second half, is not available: that key is the window's own Close and has
/// to stay so, for the reason `WindowDismissal` gives. Closing a chat tab still goes through the
/// question `SessionClosure` asks, so nothing is lost more quietly than it was.
///
/// **A split tab closes the pane the keyboard is in, not the tree.** A tab's panes each hold a
/// whole conversation or a whole shell, and closing four of them on one keystroke is not what
/// anybody means by closing a tab. Cmd+Ctrl+W is the neighbouring item that takes a pane out of
/// the arrangement while leaving what it was showing alive; this one ends the thing itself.
public enum TabClosure {
    /// The content Cmd+W acts on, or nothing when the workspace has no tab at all.
    ///
    /// - Parameters:
    ///   - selectedTab: the strip entry in front.
    ///   - focusedPaneContent: what the focused pane of that tab is showing, which for a tab
    ///     nobody has split is the tab itself.
    public static func target(
        selectedTab: PaneContent?, focusedPaneContent: PaneContent?
    ) -> PaneContent? {
        guard let selectedTab else { return nil }
        return focusedPaneContent ?? selectedTab
    }
}
