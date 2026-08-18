import Foundation

/// Shared geometry for the two completion menus, so the slash menu and the file menu cannot drift
/// apart.
enum MenuLayout {
    /// About eight rows. Past that a menu stops being a glance and starts being a list, and the
    /// composer it floats over disappears behind it.
    static let maxHeight: CGFloat = 240
}
