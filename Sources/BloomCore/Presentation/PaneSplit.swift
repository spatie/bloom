import Foundation

/// What kind of thing a centre tab that is not a conversation is showing.
///
/// It lives here rather than nested in `CenterTab` beside the views because two decisions turn on
/// it that have to be testable, and both of them are about splitting: whether Split Right and
/// Split Down are allowed to do anything at all, and what the half that opens is filled with.
/// `Tests/BloomCoreTests` cannot see `Sources/Bloom`, so a rule left there is a rule nothing can
/// hold still. `CenterTab.Kind` is a type alias onto this, so the tab type reads as it always did.
///
/// **The raw values are a file format.** They are what `center.tabs.<workspaceID>` was written
/// with, and moving the type between modules must not change a byte of it, which is why the cases
/// keep their spellings and the `String` raw type.
public enum CenterTabKind: String, Codable, Sendable, CaseIterable {
    case terminal
    case browser
    /// The changed files of this workspace, read one at a time.
    case review
    /// The workspace's scratch text.
    case notes
}

/// What goes in the half a split opens, worked out from the pane being split.
///
/// A conversation renders in two panes happily, so splitting one means what splitting means in
/// every editor: the same thing twice. A shell and a web view are each one live `NSView`, so a
/// second pane onto either takes the view away from the first and leaves it drawing nothing; those
/// two get a fresh one of the same kind instead. The review and the notes have neither: a
/// workspace has exactly one of each by design, so there is no second copy to show and no fresh
/// one to make.
public enum PaneDuplicateOutcome: Equatable, Sendable {
    /// The same conversation, in both halves.
    case sameContent
    /// A new shell in the same worktree.
    case freshTerminal
    /// A new browser, on the page the pane being split is already showing.
    case freshBrowser
    /// Nothing at all, and therefore a Split item that has to be greyed out rather than offered.
    case nothing

    /// Whether a split would actually open a second pane.
    ///
    /// This is what the View menu asks before it enables Split Right and Split Down. An item that
    /// is enabled and does nothing when it is pressed is worse than one that is greyed, because
    /// the first press teaches the user that the menu lies and there is no second lesson.
    public var opensAPane: Bool { self != .nothing }
}

/// The one place that decides what splitting a pane produces.
///
/// Said once because it used to be said twice: `PaneDuplicate` refused the review and the notes,
/// and the View menu enabled its Split items on nothing more than a workspace being selected. The
/// two disagreed, so Split Right on the Notes tab read as available and then did nothing at all,
/// with no split and no feedback. Both sides ask this now.
public enum PaneSplit {
    /// `tabKind` is the kind of the tool tab the pane is showing, or nil when `content` is a chat
    /// or names a tab that is no longer open. A pointer at a tab that has gone produces nothing,
    /// which is also what the split itself does with one, so the menu greys for it too.
    public static func duplicating(_ content: PaneContent, tabKind: CenterTabKind?) -> PaneDuplicateOutcome {
        switch content {
        case .chat:
            return .sameContent
        case .tool:
            switch tabKind {
            case .terminal: return .freshTerminal
            case .browser: return .freshBrowser
            case .review, .notes, nil: return .nothing
            }
        }
    }
}
