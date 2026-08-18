import SwiftUI
import AppKit
import BatonCore

/// One syntax highlighted line of source.
///
/// This is the hottest view in the app. A diff scrolls thousands of these past the eye, and
/// SwiftUI re-evaluates a row body far more often than the row's inputs actually change, so the
/// expensive half (lexing, then folding tokens into an `AttributedString`) is memoised on exactly
/// the three values that determine the result. The view itself does nothing but hand a cached
/// value to `Text`.
struct CodeText: View {
    private let line: String
    private let language: Language
    private let carry: LexState
    private var emphasis: [Range<String.Index>] = []
    private var emphasisColor: Color = .clear

    init(line: String, language: Language, carry: LexState) {
        self.line = line
        self.language = language
        self.carry = carry
    }

    /// Word level diff spans, painted on top of whatever background the row already has.
    ///
    /// Kept off the cache key on purpose: emphasis only ever applies to paired diff rows, and
    /// baking it into the key would halve the hit rate for every other line in the file.
    func emphasizing(_ ranges: [Range<String.Index>], color: Color) -> CodeText {
        guard !ranges.isEmpty else { return self }
        var copy = self
        copy.emphasis = ranges
        copy.emphasisColor = color
        return copy
    }

    var body: some View {
        Text(attributed)
            .font(Typo.code)
            .textSelection(.enabled)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var attributed: AttributedString {
        var value = SyntaxCache.attributed(line: line, language: language, carry: carry)
        guard !emphasis.isEmpty else { return value }

        for range in emphasis {
            guard let mapped = Self.attributedRange(for: range, of: line, in: value) else { continue }
            value[mapped].backgroundColor = emphasisColor
        }
        return value
    }

    /// The single place a `TokenKind` becomes a colour, so retuning the theme is a one-switch edit.
    nonisolated static func color(for kind: TokenKind) -> Color {
        switch kind {
        case .plain: Palette.textPrimary
        case .keyword: Palette.synKeyword
        case .type: Palette.synType
        case .string: Palette.synString
        case .number: Palette.synNumber
        case .comment: Palette.synComment
        case .function: Palette.synFunction
        case .variable: Palette.synVariable
        case .attribute: Palette.synAttribute
        case .operator: Palette.synOperator
        case .punctuation: Palette.synOperator
        case .regex: Palette.synString
        case .constant: Palette.synConstant
        }
    }

    /// Map a UTF-16 offset range onto `AttributedString` indices.
    ///
    /// Both hops can legitimately fail: a token boundary can land inside a surrogate pair or in
    /// the middle of a grapheme cluster, and `AttributedString` only addresses character
    /// boundaries. Every conversion is therefore optional or bounds checked, and a range that
    /// cannot be expressed is dropped rather than approximated, because a wrong colour on one
    /// token is invisible while a crash in a scroll view is not.
    nonisolated static func attributedRange(
        forUTF16 range: Range<Int>,
        of source: String,
        in target: AttributedString
    ) -> Range<AttributedString.Index>? {
        let limit = source.utf16.count
        guard range.lowerBound >= 0, range.upperBound <= limit, range.lowerBound < range.upperBound else {
            return nil
        }
        let lower = String.Index(utf16Offset: range.lowerBound, in: source)
        let upper = String.Index(utf16Offset: range.upperBound, in: source)
        return attributedRange(for: lower..<upper, of: source, in: target)
    }

    nonisolated static func attributedRange(
        for range: Range<String.Index>,
        of source: String,
        in target: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard range.lowerBound >= source.startIndex, range.upperBound <= source.endIndex,
              range.lowerBound < range.upperBound,
              let lower = AttributedString.Index(range.lowerBound, within: target),
              let upper = AttributedString.Index(range.upperBound, within: target),
              lower < upper
        else { return nil }
        return lower..<upper
    }
}

// MARK: - Cache

private final class SyntaxKey: NSObject {
    let line: String
    let language: Language
    let carry: LexState
    private let cachedHash: Int

    init(line: String, language: Language, carry: LexState) {
        self.line = line
        self.language = language
        self.carry = carry
        var hasher = Hasher()
        hasher.combine(line)
        hasher.combine(language)
        hasher.combine(carry)
        self.cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SyntaxKey else { return false }
        return cachedHash == other.cachedHash
            && line == other.line
            && language == other.language
            && carry == other.carry
    }
}

private final class SyntaxBox {
    let value: AttributedString

    init(_ value: AttributedString) { self.value = value }
}

/// Memoised highlighting, shared by every code view in the app.
///
/// `NSCache` rather than a dictionary: it does its own locking, so a background preparation pass
/// and the main thread can both prime it, and it evicts under memory pressure instead of growing
/// with the size of the largest file the user happened to open.
enum SyntaxCache {
    /// Roughly a few screens of several open files. Past this, re-lexing a line costs less than
    /// the memory of remembering it.
    private static let limit = 4_000

    // NSCache is documented as thread safe, which is the whole reason it is used here.
    nonisolated(unsafe) private static let storage: NSCache<SyntaxKey, SyntaxBox> = {
        let cache = NSCache<SyntaxKey, SyntaxBox>()
        cache.countLimit = limit
        return cache
    }()

    static func attributed(line: String, language: Language, carry: LexState) -> AttributedString {
        let key = SyntaxKey(line: line, language: language, carry: carry)
        if let hit = storage.object(forKey: key) { return hit.value }

        let value = build(line: line, language: language, carry: carry)
        storage.setObject(SyntaxBox(value), forKey: key)
        return value
    }

    private static func build(line: String, language: Language, carry: LexState) -> AttributedString {
        var value = AttributedString(line)
        value.foregroundColor = Palette.textPrimary
        guard !line.isEmpty else { return value }

        var state = carry
        let tokens = SyntaxHighlighter.tokenize(line: line, language: language, carry: &state)

        for token in tokens where token.kind != .plain {
            guard let range = CodeText.attributedRange(
                forUTF16: token.range, of: line, in: value
            ) else { continue }
            value[range].foregroundColor = CodeText.color(for: token.kind)
        }
        return value
    }
}

// MARK: - Carry threading

/// Lexer state per line, computed once for a whole file.
///
/// Block comments, heredocs and multiline strings only highlight correctly if the line above was
/// lexed first, which is exactly what a lazy list refuses to guarantee. Running the scanner once
/// up front, in order, and remembering the state each line *starts* in turns a sequential
/// dependency into a lookup that any row can do in any order.
enum CarryPass {
    /// The state each line begins in. Index `i` is the state before `lines[i]`.
    static func states(for lines: [String], language: Language) -> [LexState] {
        var state = LexState()
        var result: [LexState] = []
        result.reserveCapacity(lines.count)

        for line in lines {
            result.append(state)
            _ = SyntaxHighlighter.tokenize(line: line, language: language, carry: &state)
        }
        return result
    }
}

// MARK: - Metrics

/// Monospaced text lets a view compute its own width arithmetically instead of measuring, which
/// is what makes a single horizontal scroll view over a whole file affordable.
///
/// Every number here is derived from the font `Typo.code` actually resolves to, rather than from a
/// point size typed in once. That is what lets the diff follow the user's text size instead of
/// clipping the moment they make text larger.
enum CodeMetrics {
    /// The font `Typo.code` resolves to: the monospaced face at the callout text style's size.
    nonisolated(unsafe) static let font: NSFont = {
        let size = NSFont.preferredFont(forTextStyle: .callout).pointSize
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }()

    /// Width of one character in `Typo.code`.
    static let advance: CGFloat = {
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        return width > 0 ? width : 7.2
    }()

    /// One line of code, plus the small amount of air that keeps a wall of them readable. Floored
    /// at the height the diff was designed around so the default appearance is unchanged.
    static let rowHeight: CGFloat = max(16, ceil(font.ascender - font.descender + font.leading) + 3)

    /// The `+` or `-` column. One character wide, plus its own breathing room.
    static let markerWidth: CGFloat = ceil(advance) + 4

    /// Four digits, which covers every file anyone reads a diff of by hand.
    static let numberWidth: CGFloat = ceil(advance * 4) + gutterPadding

    /// Between a line number and whatever sits next to it.
    static let gutterPadding: CGFloat = 4
    /// Between the marker column and the first character of code.
    static let textInset: CGFloat = 8

    /// Display columns a line occupies, counting a tab as four so the width estimate does not
    /// fall short on indented code.
    static func columns(of line: String) -> Int {
        var count = 0
        for character in line {
            count += character == "\t" ? 4 : 1
        }
        return count
    }
}
