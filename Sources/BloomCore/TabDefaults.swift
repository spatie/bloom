import Foundation

/// Where the centre column's tabs and the arrangement inside each of them are filed.
///
/// Gathered in one place because three separate readers have to agree on them and two of them are
/// migrations: get a prefix wrong and the arrangement is not lost, it is invisible, which looks
/// exactly the same and heals by itself only if somebody notices.
public enum TabDefaults {
    /// The carve a workspace used to own, before a tab owned one. A key still here is a workspace
    /// that has not been through phase A.
    public static let legacyCentrePrefix = "center.panes."

    /// One tab's arrangement, keyed by the id of the content at its root.
    ///
    /// Deliberately singular, and it does not collide with `center.tabs.<workspaceID>`, which is
    /// the tool tab list `CenterTabStore` writes: the character after `center.tab` is `s` there
    /// and `.` here, so a scan for this prefix cannot pick the list up. The near miss is worth
    /// saying out loud, because a scan that swallowed the list would read it as an arrangement,
    /// fail to decode it, and throw away every terminal and browser tab the user had open.
    public static let tabPrefix = "center.tab."

    public static func tabKey(_ rootContentID: String) -> String { tabPrefix + rootContentID }

    public static func tabKey(root: PaneContent) -> String { tabKey(root.id) }

    /// `CenterTabStore`'s list of tool tabs, per workspace. Plural, and see the near miss above.
    ///
    /// Here rather than private to the store because `TerminalPaneCensus` reads the same key, and
    /// the two used to say it separately. That duplication is the most dangerous kind this app
    /// has: the census enumerates every pane the orphan sweep may keep, so a prefix that drifted
    /// on one side and not the other would have the sweep see no panes at all and kill every tmux
    /// session behind them. A killed shell cannot be got back. One literal, read by both.
    public static let tabListPrefix = "center.tabs."

    public static func tabListKey(_ workspaceID: WorkspaceID) -> String {
        tabListPrefix + workspaceID.rawValue
    }

    /// `TerminalSplitStore`'s pane tree, per tab, and the second half of what the census reads.
    /// Same argument as `tabListPrefix`: a tab whose tree cannot be found reads as a single pane,
    /// so every pane the user split off would look unreachable and be swept.
    public static let splitPrefix = "terminal.split."

    public static func splitKey(_ tabID: String) -> String { splitPrefix + tabID }
}
