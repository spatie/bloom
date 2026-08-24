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
    case slash(Token)
    case mention(Token)

    /// A part-typed `/command` or `@path`, measured in UTF-16 units, the unit `NSTextView` reports
    /// its caret in, so a path with an emoji in it cannot shift the replacement range by a
    /// character.
    ///
    /// One type for both, because the two tokens are the same shape and the same rules, and the
    /// one time they were not was the bug this file was last changed for: `@` was found by
    /// scanning back from the caret and so worked anywhere in a sentence, while `/` demanded that
    /// the whole draft be a single `/word` and so worked only as the first thing typed. Somebody
    /// writing "do a /rev" got nothing, having just been offered a menu for "@Sou" in the same
    /// box. Sharing the token and the boundary test is what stops the pair drifting apart again.
    public struct Token: Equatable, Sendable {
        public var start: Int
        public var length: Int
        public var query: String

        public init(start: Int, length: Int, query: String) {
            self.start = start
            self.length = length
            self.query = query
        }

        /// One past the last character of the token.
        public var end: Int { start + length }
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
        case .slash(let token), .mention(let token): token.query
        }
    }

    public var slash: Token? {
        guard case .slash(let token) = self else { return nil }
        return token
    }

    public var mention: Token? {
        guard case .mention(let token) = self else { return nil }
        return token
    }

    public static func resolve(draft: String, caret: Int) -> ComposerMenu {
        if let token = slashToken(in: draft, caret: caret) { return .slash(token) }
        if let token = mentionToken(in: draft, caret: caret) { return .mention(token) }
        return .none
    }

    /// A part-typed `/command` ending at the caret.
    ///
    /// The slash has to begin a word. A slash glued to the character before it is punctuation in
    /// something else and never a command: without that test every `src/main.swift`, every
    /// `https://x` and every `23/08` in a prompt would open the menu, which is worse than not
    /// offering the menu at all.
    public static func slashToken(in draft: String, caret: Int) -> Token? {
        token(in: draft, caret: caret, opener: "/")
    }

    public static func mentionToken(in draft: String, caret: Int) -> Token? {
        token(in: draft, caret: caret, opener: "@")
    }

    /// The nearest `opener` before the caret, when it begins a word and nothing since it is
    /// whitespace.
    ///
    /// Searched backwards, so the token is the one being typed rather than the first one in the
    /// draft. Whitespace after the opener ends the token and closes the menu, which is why a
    /// finished `/review the diff` is silent while `/rev` is not.
    private static func token(in draft: String, caret: Int, opener: String) -> Token? {
        let text = draft as NSString
        let location = min(max(caret, 0), text.length)
        guard location > 0 else { return nil }

        let before = text.substring(to: location) as NSString
        let found = before.range(of: opener, options: .backwards)
        guard found.location != NSNotFound else { return nil }

        let query = before.substring(from: found.location + 1)
        guard !query.contains(where: isBreak) else { return nil }
        guard beginsAWord(in: before, at: found.location) else { return nil }

        return Token(start: found.location, length: location - found.location, query: query)
    }

    /// Whether the character before `at` lets a token start there.
    ///
    /// Whitespace, or nothing at all, is the safe rule. An opening bracket is allowed as well
    /// because a path or a command written into a parenthetical, `(@Sources/Bloom)`, is still the
    /// thing being named, and an `@` or a `/` after a letter is an email address, a package name
    /// or a file path.
    private static func beginsAWord(in text: NSString, at location: Int) -> Bool {
        guard location > 0 else { return true }
        let previous = text.substring(with: NSRange(location: location - 1, length: 1))
        return [" ", "\n", "\t", "(", "["].contains(previous)
    }

    private static func isBreak(_ character: Character) -> Bool {
        character == " " || character == "\n" || character == "\t"
    }
}
