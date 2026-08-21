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
}
