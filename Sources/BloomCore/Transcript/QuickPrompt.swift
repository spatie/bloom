import Foundation

/// A few lines the owner wrote and keeps typing again, kept by Bloom so they can be put back in
/// the box with two keystrokes.
///
/// Bloom's own row rather than a file in `.claude/commands`, and that is the decision this type
/// exists to record. A file in that directory is a slash command: the CLI reads it in the terminal
/// pane too, it sits beside skills, and it is offered by `SlashCommandCatalog` under a leading
/// slash. Two things that looked identical would then behave differently depending on which of the
/// two lists they came out of. The price of the row is that a quick prompt is Bloom's alone: it
/// does not work in the terminal and it does not travel with the repository.
///
/// The same small shape as `RunScript`, which is the precedent for "a named thing the owner wrote",
/// with a symbol on it because five rows of identical text are a worse list than five rows with a
/// mark down the left.
public struct QuickPrompt: Identifiable, Sendable, Hashable {
    public var id: QuickPromptID
    /// What the row is called. Short, and searched first.
    public var name: String
    /// The mark down the left of the row: either an SF Symbol name from `symbols` below, or one
    /// emoji. A string rather than an enum case, because the picker can grow without every stored
    /// row having to still resolve to a case that is on it, and because a row written when this
    /// held nothing but symbol names still reads back correctly. `QuickPromptMark` is what tells
    /// the two apart.
    public var symbol: String
    /// The words that go into the draft. Where they land, and whether they go on their own, is
    /// `QuickPromptDelivery` reading the two switches below.
    public var text: String
    /// Whether choosing it sends the words rather than leaving them in the composer to be edited.
    ///
    /// Off for every prompt written before this existed, which is what the migration on
    /// `quick_prompt` defaults it to. The whole library behaved that way for its whole life, and a
    /// stored row must not change what it does because Bloom learned a new column.
    public var sendsImmediately: Bool
    /// Whether choosing it opens a new chat for the words rather than using the one on screen.
    /// Off by default, for the reason above.
    public var opensNewChat: Bool
    /// Where it sits in the list. There is no reordering, so this only ever says which order they
    /// were written in; search is the ordering anybody actually uses.
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: QuickPromptID = .new(),
        name: String,
        symbol: String = QuickPrompt.defaultSymbol,
        text: String,
        sendsImmediately: Bool = false,
        opensNewChat: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.text = text
        self.sendsImmediately = sendsImmediately
        self.opensNewChat = opensNewChat
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// Everything about a prompt the owner chooses, which is everything the form writes.
    ///
    /// A value rather than five arguments, because the form hands this down through a closure and
    /// a catalogue method, and `onSave(name, symbol, text, true, false)` is a call nobody can read
    /// at either end. The id, the order and the date are not here: none of the three is a thing a
    /// person types, and all three belong to the row rather than to what is written into it.
    public struct Fields: Sendable, Equatable {
        public var name: String
        public var symbol: String
        public var text: String
        public var sendsImmediately: Bool
        public var opensNewChat: Bool

        public init(
            name: String,
            symbol: String = QuickPrompt.defaultSymbol,
            text: String,
            sendsImmediately: Bool = false,
            opensNewChat: Bool = false
        ) {
            self.name = name
            self.symbol = symbol
            self.text = text
            self.sendsImmediately = sendsImmediately
            self.opensNewChat = opensNewChat
        }
    }

    /// What the form opens with, and what it writes back.
    public var fields: Fields {
        get {
            Fields(
                name: name,
                symbol: symbol,
                text: text,
                sendsImmediately: sendsImmediately,
                opensNewChat: opensNewChat
            )
        }
        set {
            name = newValue.name
            symbol = newValue.symbol
            text = newValue.text
            sendsImmediately = newValue.sendsImmediately
            opensNewChat = newValue.opensNewChat
        }
    }

    /// What a row without an icon gets, and what an unknown symbol name falls back to.
    public static let defaultSymbol = "text.alignleft"

    /// Every SF Symbol the picker offers, read off `QuickPromptMarkCatalog` rather than written
    /// out again here.
    ///
    /// It was eighteen names in this file, one band of six by three drawn inline on the form, on
    /// the argument that a browser of six thousand symbols would be a bigger decision than the
    /// prompt itself. That argument still holds against a symbol *search*, and the picker is not
    /// one: it is a hundred marks the owner chose, in nine named bands, behind a square. What
    /// changed is that eighteen was not enough to tell twenty prompts apart.
    ///
    /// Derived rather than duplicated, because a second copy of the list is a copy that drifts,
    /// and the only thing that would notice is a row drawn with the fallback for no visible reason.
    public static let symbols: [String] = QuickPromptMarkCatalog.all.compactMap {
        guard case .symbol(let name) = $0.mark else { return nil }
        return name
    }

    /// The same list as a set, because `QuickPromptMark` asks it once per row drawn.
    static let knownSymbols = Set(symbols)

    /// A stored value resolved to something that can actually be drawn: the symbol name, the
    /// emoji, or the fallback for anything else. Kept under its old name because the column it
    /// reads is still called `symbol` and every row written before emoji holds one.
    ///
    /// A view wants `QuickPromptMark(stored:)` instead, since only that says which of the two it
    /// got and therefore whether to reach for `Image(systemName:)` or for `Text`.
    public static func resolvedSymbol(_ symbol: String) -> String {
        QuickPromptMark(stored: symbol).stored
    }

    /// The second line of a row: the first stretch of the text itself.
    ///
    /// A name chosen badly six weeks ago is still recoverable from it, which is the whole reason
    /// the row is two lines. Newlines are folded into spaces because the row is one line high and
    /// a prompt that begins with a heading would otherwise show the heading and nothing else.
    public var preview: String {
        let folded = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard folded.count > Self.previewLength else { return folded }
        return folded.prefix(Self.previewLength).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// About as much as fits on the second line of the panel's row. See
    /// `QuickPromptMenu.width`.
    static let previewLength = 72

    /// The name with the whitespace taken off both ends, or a name made from the text when the
    /// owner left the field empty. A row with no name at all is a row nobody can search for.
    public var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return preview
    }

    /// What a chat opened for this prompt is called, or nil for the strip's own numbered `Chat`.
    ///
    /// The name the owner typed, and only that. `PaneNaming` is emphatic that a chat is furniture
    /// rather than a description of what is in it, with the exception it names being a chat opened
    /// FOR something, which is what the pull request and merge buttons pass a title for. A quick
    /// prompt somebody called "Ship it" is exactly that case. A quick prompt with no name is not:
    /// `resolvedName` would hand the strip the first stretch of the words, which is the fragment of
    /// somebody's sentence that rule exists to keep out of the tab bar.
    public var chatTitle: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the row has anything to say on a second line.
    ///
    /// False for a prompt with no name, because `resolvedName` is already its first line and the
    /// row drew the same sentence twice, once in the name's weight and once in the preview's. A
    /// name somebody wrote is a different fact from the words, and only then are there two of them.
    public var hasSeparatePreview: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
