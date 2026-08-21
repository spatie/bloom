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
enum PaneKind: String, CaseIterable, Identifiable, Sendable {
    case chat
    case terminal
    case browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .terminal: "Terminal"
        case .browser: "Browser"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .terminal: "apple.terminal"
        case .browser: "globe"
        }
    }
}
