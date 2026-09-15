import SwiftUI
import BloomClient

/// Applies the shared lexer to one line while allowing callers to carry either side of a diff.
@MainActor
enum BloomSyntaxText {
    static func line(_ line: String, language: Language, carry: inout LexState, scheme: ColorScheme) -> AttributedString {
        var value = AttributedString(line)
        for token in SyntaxHighlighter.tokenize(line: line, language: language, carry: &carry) {
            guard let range = Range(NSRange(location: token.range.lowerBound, length: token.range.count), in: line),
                  let lower = AttributedString.Index(range.lowerBound, within: value),
                  let upper = AttributedString.Index(range.upperBound, within: value) else { continue }
            value[lower..<upper].foregroundColor = colour(token.kind, scheme: scheme)
        }
        return value
    }

    private static func colour(_ kind: TokenKind, scheme: ColorScheme) -> Color {
        let pair: PaletteInk.Pair? = switch kind {
        case .keyword: PaletteInk.synKeyword
        case .type: PaletteInk.synType
        case .string, .regex: PaletteInk.synString
        case .number, .constant: PaletteInk.synNumber
        case .comment: PaletteInk.synComment
        case .function: PaletteInk.synFunction
        case .variable: PaletteInk.synVariable
        case .attribute: PaletteInk.synAttribute
        case .operator: PaletteInk.synOperator
        case .plain, .punctuation: nil
        }
        return pair.map { BloomColour.resolve($0, scheme: scheme) } ?? .primary
    }
}
