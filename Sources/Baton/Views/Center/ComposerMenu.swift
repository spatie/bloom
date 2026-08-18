import Foundation

/// Which completion menu the draft is asking for.
///
/// The draft plus the caret is enough to know which menu belongs on screen, so there is no
/// separate "menu is open" flag to get out of step with the text. Everything here is pure, which
/// is what lets the composer stay a view and lets the rules be tested on their own.
enum ComposerMenu: Equatable {
    case none
    case slash(String)
    case mention(MentionToken)

    /// A part-typed `@path`, measured in UTF-16 units, the unit `NSTextView` reports its caret in,
    /// so a path with an emoji in it cannot shift the replacement range by a character.
    struct MentionToken: Equatable {
        var start: Int
        var length: Int
        var query: String
    }

    /// Identity without the query, so the composer can tell "still the same menu, longer query"
    /// from "a different menu entirely".
    enum Kind {
        case none
        case slash
        case mention
    }

    var kind: Kind {
        switch self {
        case .none: .none
        case .slash: .slash
        case .mention: .mention
        }
    }

    var query: String? {
        switch self {
        case .none: nil
        case .slash(let query): query
        case .mention(let token): token.query
        }
    }

    var mention: MentionToken? {
        guard case .mention(let token) = self else { return nil }
        return token
    }

    static func resolve(draft: String, caret: Int) -> ComposerMenu {
        if let query = slashQuery(in: draft) { return .slash(query) }
        if let token = mentionToken(in: draft, caret: caret) { return .mention(token) }
        return .none
    }

    /// A slash command is only offered while the whole draft is one unbroken `/word`, because that
    /// is the only shape the CLI treats as a command.
    static func slashQuery(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return nil }
        return String(rest)
    }

    static func mentionToken(in draft: String, caret: Int) -> MentionToken? {
        let text = draft as NSString
        let location = min(max(caret, 0), text.length)
        guard location > 0 else { return nil }

        let before = text.substring(to: location) as NSString
        let at = before.range(of: "@", options: .backwards)
        guard at.location != NSNotFound else { return nil }

        let query = before.substring(from: at.location + 1)
        guard !query.contains(" "), !query.contains("\n"), !query.contains("\t") else { return nil }

        // An `@` in the middle of a word is an email address or a package name, not a mention.
        if at.location > 0 {
            let previous = before.substring(with: NSRange(location: at.location - 1, length: 1))
            guard [" ", "\n", "\t", "(", "["].contains(previous) else { return nil }
        }

        return MentionToken(start: at.location, length: location - at.location, query: query)
    }
}
