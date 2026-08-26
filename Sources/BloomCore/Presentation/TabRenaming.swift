import Foundation

/// Which tabs of the centre strip can be given a name.
///
/// One rule, read by the tab itself and by the File menu's Rename Tab. It was the tab's alone, as
/// `tab.kind != .review && tab.kind != .notes` written inside a view, until the menu bar grew an
/// item that has to grey against the same answer. Two spellings of it would eventually let a menu
/// item open a field on a tab that has no name to change.
public enum TabRenaming {
    /// - Parameter tabKind: the kind of the tool tab, or nil when `content` is a conversation or
    ///   points at a tab that is no longer open.
    ///
    /// **The review and the notes are refused.** A workspace has exactly one of each by design and
    /// both are named after what they show, so a name written on either would be a label with
    /// nothing behind it: reopening the tab draws the fixed title again. Every other tab carries a
    /// name somebody chose, or a name taken from what is in it, and both are worth editing.
    ///
    /// A pointer at a tab that has gone is refused as well, which is the same answer `PaneSplit`
    /// gives it, so the menu greys rather than opening a field on nothing.
    public static func canRename(_ content: PaneContent, tabKind: CenterTabKind?) -> Bool {
        switch content {
        case .chat:
            return true
        case .tool:
            switch tabKind {
            case .terminal, .browser: return true
            case .review, .notes, nil: return false
            }
        }
    }
}
