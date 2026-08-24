import Foundation

/// The two marks a person puts on a workspace by hand.
///
/// Everything else a sidebar row draws is reported rather than chosen: the status glyph is what
/// `WorkspaceStatus` worked out, the diff counts are what `git` said, the unread weight is what a
/// finishing turn wrote. These two are the opposite. Nothing sets them but the user, nothing
/// clears them but the user or the one rule written out below, and they exist so a person can say
/// something about a row that the machine has no way to know.
///
/// They live here, in the core, rather than in the menus that offer them, because both lists offer
/// them and the answer must not depend on which list you right clicked in. `WorkspaceMenuItems`
/// draws what these decide.

// MARK: - The unread mark

/// What the row menu's unread item should say, or nothing when it should not be there at all.
///
/// One item that changes its label rather than two items, because the two are the same decision
/// seen from either side, and a menu that lists both always has one of them greyed out or lying.
/// Marking read is worth offering in its own right: it is the only way to clear the Dock badge
/// for a workspace without opening it, which is exactly what somebody who already knows what the
/// agent did wants.
public enum UnreadMarkAction: String, Sendable, Hashable, CaseIterable {
    /// The workspace has been read. The item offers to put the mark back.
    case markUnread
    /// The workspace is unread. The item offers to clear the mark.
    case markRead

    public var title: String {
        switch self {
        case .markUnread: "Mark as Unread"
        case .markRead: "Mark as Read"
        }
    }

    /// What the item writes to `Workspace.unread`.
    public var unread: Bool {
        self == .markUnread
    }
}

public enum WorkspaceUnreadMark {
    /// The item to offer for this workspace, or nil when there should be no item.
    ///
    /// **Archived workspaces get nothing.** An archived row's `unread` is a leftover with nothing
    /// behind it and nothing that reads it: `DockBadge` counts `AppModel.workspaces`, which holds
    /// active workspaces only, and the sidebar never lists an archived workspace at all. Opening
    /// one goes to `ArchivedWorkspaceView`, which deliberately marks nothing read because there
    /// is nothing to go back to. So an item here would write a flag that no part of the app draws
    /// and that the user has no way to answer.
    ///
    /// The two states also say opposite things: unread means "this wants you", archived means
    /// "this is done with you". A row cannot be both, and the one the owner acted on last is the
    /// one that is true.
    ///
    /// Home used to restate all of that above a copy of the rule. `isUnread` below is that copy,
    /// deleted and pointed here, because a rule written twice is a rule that can disagree with
    /// itself about one workspace.
    ///
    /// Everything else is offered, including a workspace whose agent is mid turn. That mark is
    /// short lived, because the turn writes `unread` when it finishes (see
    /// `TranscriptModel.notifyFinished`), and being overwritten is right: how the turn went is
    /// newer information than a reminder set before it ended.
    public static func action(for workspace: Workspace) -> UnreadMarkAction? {
        guard workspace.state == .active else { return nil }
        return workspace.unread ? .markRead : .markUnread
    }

    /// Whether a row should draw the unread weight at all.
    ///
    /// The same rule as `action(for:)` and deliberately built on it, because it IS the same
    /// question: an item that would offer "Mark as Read" is an item on a row that is showing as
    /// unread. `HomeListRow` wrote it out a third time as `!row.isArchived && workspace.unread`,
    /// with the whole argument for it restated in a comment above, and the comment already said
    /// the two had to end the same way or they would disagree about one workspace. Two statements
    /// of a rule that must agree is one statement too many.
    ///
    /// It asks `workspace.state` rather than a row's own archived flag, which is the field the
    /// store writes and the one every other reader of this rule uses.
    public static func isUnread(_ workspace: Workspace) -> Bool {
        action(for: workspace) == .markRead
    }
}

// MARK: - The colour

/// One of the colours a workspace can be marked with, as it is offered in a menu.
///
/// A name as well as a hex, because the only shape a colour picker can take in a menu on this
/// platform is a list of named rows: a row of bare swatches is not merely ugly there, it does not
/// render at all. Measured, not assumed. See `WorkspaceMenuItems` for what was tried.
///
/// The hexes are `Accent.all`, every one of them, which is the whole point of this type. Projects
/// were already handed colours out of that list, and a second list invented for workspaces would
/// put two reds four points apart in the same sidebar row. `theTenColoursAreTheAccentSet` in
/// `WorkspaceColourTests` is what keeps them from drifting.
///
/// The order is not `Accent.all`'s. That one is an assignment order, arranged so the first few
/// projects added to a fresh install come out obviously different from each other. A menu is read
/// down, so these run around the wheel and finish on the one colour that is not on it.
public struct WorkspaceColour: Identifiable, Sendable, Hashable, Codable {
    public let name: String
    public let hex: String

    public var id: String { hex }

    public init(name: String, hex: String) {
        self.name = name
        self.hex = hex
    }

    public static let all: [WorkspaceColour] = [
        WorkspaceColour(name: "Red", hex: "E2725B"),
        WorkspaceColour(name: "Orange", hex: "E06C2A"),
        WorkspaceColour(name: "Yellow", hex: "D9A21B"),
        WorkspaceColour(name: "Lime", hex: "5B8C2A"),
        WorkspaceColour(name: "Green", hex: "22A06B"),
        WorkspaceColour(name: "Teal", hex: "2FA8A8"),
        WorkspaceColour(name: "Blue", hex: "4C8DF6"),
        WorkspaceColour(name: "Purple", hex: "9B6DE0"),
        WorkspaceColour(name: "Pink", hex: "D8608C"),
        WorkspaceColour(name: "Grey", hex: "6C7A89"),
    ]

    /// The entry a stored value names, or nil for a colour that is not in the list.
    ///
    /// Case insensitive, because a hex is text and text arrives in whatever case wrote it.
    ///
    /// Nil is not a failure and a caller must not treat it as one. What a workspace stores is a
    /// hex, not an index into this list, so a colour picked before the list changed, or written by
    /// something that is not this menu, is still a real colour and is still drawn. This answers
    /// only "does the menu have a name for it", which is a question about the menu.
    public static func named(_ hex: String) -> WorkspaceColour? {
        all.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }
}

public extension Workspace {
    /// The colour this workspace is marked with, as something that can be drawn, or nil.
    ///
    /// Goes through `HexColor` rather than handing the stored string to a colour type directly, so
    /// a value that is not a colour draws nothing instead of drawing whatever a lenient parser
    /// made of it. That is the bug `HexColor` was written for.
    var colourMark: HexColor? {
        colour.flatMap(HexColor.init(hex:))
    }

    /// What a screen reader and a tooltip call the colour, or nil when there is none.
    ///
    /// The name when the list has one and the hex when it does not, because "Colour #7F3FBF" is
    /// still an answer and "Colour" on its own is not.
    var colourDescription: String? {
        guard let colour, colourMark != nil else { return nil }
        return WorkspaceColour.named(colour)?.name ?? "#\(colour)"
    }
}
