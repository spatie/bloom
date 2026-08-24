import Foundation

/// The three kinds of thing a pane can be opened on, and what each of them is called.
///
/// The nouns and the glyphs live here for the reason `PaneSymbol` exists: the strip's `+` menu and
/// the split submenus of both the centre pane and a terminal pane now offer the same three items,
/// and three literals in three files drift the first time one of them is renamed. A menu where
/// Browser wears a globe in one place and something else in another is worse than a menu with no
/// glyphs at all.
///
/// Its own file rather than sitting beside `NewPane`, which is what opens one, because a menu that
/// only names a kind should not have to reach past the machinery that makes one to say the word.
///
/// A review is deliberately not one of these. A workspace has exactly one of it, opening it twice
/// points the one tab at another file rather than making a second, and `FileReview` is the door
/// for that. See the note on `CenterTab`.
///
/// In the core because the `+` menu is no longer the only thing that names a kind: `pane_open` and
/// `pane_split` let an agent ask for one over the bridge, and a second list of the same three
/// words is exactly what the head of this file argues against. The raw values are the wire format
/// those tools accept, so renaming a case is a change to the tool contract and not only to a menu.
public enum PaneKind: String, CaseIterable, Identifiable, Sendable {
    case chat
    case terminal
    case browser

    public var id: String { rawValue }

    /// The names themselves are `PaneNaming` in the core, because what a new pane is CALLED is
    /// the same fact as what the menu item offering one says, and two of the strip's three kinds
    /// were numbering themselves off a second copy of the words.
    public var title: String {
        switch self {
        case .chat: PaneNaming.chat
        case .terminal: PaneNaming.terminal
        case .browser: PaneNaming.browser
        }
    }

    /// And the glyphs are `PaneGlyph`, for the reason the head of this file gives: the menu item
    /// and the tab it opens have to wear the same mark, and they were stating it separately.
    public var symbol: String {
        switch self {
        case .chat: PaneGlyph.chat
        case .terminal: PaneGlyph.terminal
        case .browser: PaneGlyph.browser
        }
    }
}
