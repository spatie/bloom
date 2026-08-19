import SwiftUI
import AppKit
import BloomCore

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
