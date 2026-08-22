import Foundation

/// Which completion menu the draft is asking for.
///
/// The draft plus the caret is enough to know which menu belongs on screen, so there is no
/// separate "menu is open" flag to get out of step with the text. Everything here is pure, which
/// is what lets the composer stay a view and lets the rules be tested on their own. It lives in
/// the core for exactly that reason: while it sat beside the composer the test suite could not
/// see it, and `SlashCommandTests` held a hand copied duplicate of `slashQuery` to the same
/// answers, which is the arrangement that drifts.
public enum ComposerMenu: Equatable, Sendable {
    case none
    case slash(String)
    case mention(MentionToken)

    /// A part-typed `@path`, measured in UTF-16 units, the unit `NSTextView` reports its caret in,
    /// so a path with an emoji in it cannot shift the replacement range by a character.
    public struct MentionToken: Equatable, Sendable {
        public var start: Int
        public var length: Int
        public var query: String

        public init(start: Int, length: Int, query: String) {
            self.start = start
            self.length = length
            self.query = query
        }
    }

    /// Identity without the query, so the composer can tell "still the same menu, longer query"
    /// from "a different menu entirely".
    public enum Kind: Sendable {
        case none
        case slash
        case mention
    }

    public var kind: Kind {
        switch self {
        case .none: .none
        case .slash: .slash
        case .mention: .mention
        }
    }

    public var query: String? {
        switch self {
        case .none: nil
        case .slash(let query): query
        case .mention(let token): token.query
        }
    }

    public var mention: MentionToken? {
        guard case .mention(let token) = self else { return nil }
        return token
    }

    public static func resolve(draft: String, caret: Int) -> ComposerMenu {
        if let query = slashQuery(in: draft) { return .slash(query) }
        if let token = mentionToken(in: draft, caret: caret) { return .mention(token) }
        return .none
    }

    /// A slash command is only offered while the whole draft is one unbroken `/word`, because that
    /// is the only shape the CLI treats as a command.
    public static func slashQuery(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return nil }
        return String(rest)
    }

    public static func mentionToken(in draft: String, caret: Int) -> MentionToken? {
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
