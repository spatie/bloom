import Foundation

/// The field at the head of the panel: what has been typed, which mode that put the panel in, and
/// what typing had been done before a mode was entered.
///
/// It is a value rather than three properties on the view because the three move together and
/// getting them out of step is the whole class of bug here: a `>` left in the text as well as in
/// the pill searches for a workspace called "> merge", and a mode left behind by an empty field
/// searches the menu bar for a workspace name.
///
/// **`>` counts only as the first character.** Anywhere else it is a character like any other,
/// because a branch called `feature>thing` is a thing somebody can have and a search that refused
/// to look for it would be a search with a secret.
///
/// **Leaving a mode puts the earlier query back.** Pushing into a workspace's own menu from a
/// search for `docs` and then backing out to an empty field would make Backspace a way of losing
/// what you typed, and the panel is a place people back out of constantly.
public struct SearchPanelField: Equatable, Sendable {
    public private(set) var mode: SearchPanelMode = .things
    public private(set) var text: String = ""
    /// What was in the field before a mode was entered, restored when the mode is left.
    private var stashed = ""

    public init() {}

    /// The character that switches to commands, as the first thing typed.
    public static let commandPrefix: Character = ">"

    /// What the field says after somebody has typed into it.
    ///
    /// The prefix is read only while the panel is searching things, so a command called
    /// "> something" cannot put an already-open command list into itself.
    public mutating func type(_ typed: String) {
        guard mode == .things, let first = typed.first, first == Self.commandPrefix else {
            text = typed
            return
        }
        stashed = ""
        mode = .commands
        // The one space after the prefix goes with it, so `> merge` and `>merge` are the same
        // query rather than two, the second of which matches nothing.
        var rest = String(typed.dropFirst())
        if rest.first == " " { rest.removeFirst() }
        text = rest
    }

    /// Pushes into one workspace's own menu. False when the panel is already in a mode, because a
    /// list of actions has no rows to push into and a command has no workspace of its own.
    public mutating func enterActions(on workspaceID: WorkspaceID) -> Bool {
        guard mode == .things else { return false }
        stashed = text
        mode = .actions(workspaceID)
        text = ""
        return true
    }

    /// Backspace with nothing in the field. False when there is no mode to leave, which hands the
    /// key back so it can do what Backspace does everywhere else.
    public mutating func leaveMode() -> Bool {
        guard mode != .things else { return false }
        mode = .things
        text = stashed
        stashed = ""
        return true
    }

    /// Escape's first press, and the Clear button on the field.
    public mutating func clear() {
        text = ""
    }

    public var isEmpty: Bool { text.isEmpty }

    /// What the transcript half and the name half are actually asked, which is the text with the
    /// prefix already taken off it by `type`.
    public var query: String { text }
}
