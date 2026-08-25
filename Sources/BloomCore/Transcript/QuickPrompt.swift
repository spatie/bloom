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
    /// An SF Symbol from `symbols` below. A name rather than an enum case, because the grid can
    /// grow without every stored row having to still resolve to a case that is on it.
    public var symbol: String
    /// The words that go into the draft. Never sent on their own: see `QuickPromptInsertion`.
    public var text: String
    /// Where it sits in the list. There is no reordering, so this only ever says which order they
    /// were written in; search is the ordering anybody actually uses.
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: QuickPromptID = .new(),
        name: String,
        symbol: String = QuickPrompt.defaultSymbol,
        text: String,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.text = text
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// What a row without an icon gets, and what an unknown symbol name falls back to.
    public static let defaultSymbol = "text.alignleft"

    /// The grid the form offers, and deliberately not a symbol search.
    ///
    /// The icon is here to tell five rows apart at a glance rather than to express anything, so a
    /// browser of six thousand symbols would be a bigger decision than the prompt itself. Eighteen
    /// is one screenful of six by three, which is small enough to pick from without reading.
    public static let symbols: [String] = [
        "text.alignleft", "envelope", "list.bullet", "pencil", "gearshape", "bolt",
        "checkmark.seal", "exclamationmark.triangle", "arrow.triangle.2.circlepath", "hammer",
        "magnifyingglass", "scissors", "book", "paintbrush", "ladybug", "shippingbox",
        "doc.richtext", "sparkles",
    ]

    /// Whether a stored symbol is one the grid can still show as chosen. A row written by a later
    /// build, or by hand, is drawn with the fallback rather than with nothing.
    public static func resolvedSymbol(_ symbol: String) -> String {
        symbols.contains(symbol) ? symbol : defaultSymbol
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

    /// Whether the row has anything to say on a second line.
    ///
    /// False for a prompt with no name, because `resolvedName` is already its first line and the
    /// row drew the same sentence twice, once in the name's weight and once in the preview's. A
    /// name somebody wrote is a different fact from the words, and only then are there two of them.
    public var hasSeparatePreview: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
