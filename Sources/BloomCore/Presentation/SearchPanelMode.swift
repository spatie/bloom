import Foundation

/// Which of the three things the panel is searching, and how a person gets between them.
///
/// **One prefix, and no sigil zoo.** VS Code has `>`, `@`, `#`, `:` and `?` plus word prefixes,
/// and almost nobody gets past the first. Here `@` and `/` already mean a file mention and a slash
/// command in the composer, and teaching a second meaning for either is how a keystroke stops
/// being reflexive. So there is exactly one prefix, `>`, and everything else that would have been
/// a sigil is a scope chip: Home already draws those, already names them and already tests them.
///
/// A mode is entered by typing and left with Backspace on an empty field, which is GitHub's scope
/// model rather than an invention: you narrow forwards and widen backwards, and the chip in the
/// field is what tells you which of the two you are in.
public enum SearchPanelMode: Equatable, Sendable {
    /// Workspaces, transcripts and, quietly under them, the commands whose names match.
    case things
    /// The menu bar, grouped by the menu each item lives in.
    case commands
    /// One workspace's own menu, pushed into from its row. See `SearchPanelActions`.
    case actions(WorkspaceID)

    /// The word drawn in the pill at the head of the field. Nothing at rest, because a pill saying
    /// "Everything" would be a label on the state you are in most of the time.
    public var pill: String? {
        switch self {
        case .things: nil
        case .commands: "Commands"
        // The workspace's name is the app target's to look up, so the pill for an action list is
        // completed there. This says only that there is one.
        case .actions: "Action"
        }
    }

    /// Whether the scope chips are drawn. They split an answer about workspaces and transcripts,
    /// and neither of the other two modes has one to split.
    public var showsScopes: Bool { self == .things }

    public var workspaceID: WorkspaceID? {
        if case .actions(let id) = self { return id }
        return nil
    }
}
