import SwiftUI
import BloomCore

/// A single text view can change its contents on every delta without changing the stack of
/// markdown blocks and native text views underneath SwiftUI's layout engine.
struct StreamingMarkdownView: View {
    let text: String

    @Environment(\.fontScale) private var fontScale
    @Environment(\.chatFont) private var chatFont

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(StreamingMarkdownText.render(text, scale: fontScale, face: chatFont))
            .opensTranscriptLinks()
    }
}

@MainActor
private enum StreamingMarkdownText {
    /// SwiftUI can ask for the same body more than once between deltas. Keep only the current
    /// prefix so a live answer cannot evict the cached attributed text of settled rows.
    private static var cached: (text: String, scale: CGFloat, face: ChatFont, rendered: AttributedString)?

    static func render(_ text: String, scale: CGFloat, face: ChatFont) -> AttributedString {
        if let cached, cached.text == text, cached.scale == scale, cached.face == face {
            return cached.rendered
        }
        let rendered = blocks(MarkdownParser.parse(text), scale: scale, face: face)
        cached = (text, scale, face, rendered)
        return rendered
    }

    private static func blocks(
        _ values: [MarkdownBlock], scale: CGFloat, face: ChatFont,
        separator: String = "\n\n"
    ) -> AttributedString {
        var result = AttributedString()
        for (index, value) in values.enumerated() {
            if index > 0 { result += AttributedString(separator) }
            result += block(value, scale: scale, face: face)
        }
        return result
    }

    private static func block(_ value: MarkdownBlock, scale: CGFloat, face: ChatFont) -> AttributedString {
        switch value {
        case let .paragraph(inline):
            return styled(inline, rung: Typo.body, scale: scale, face: face)
        case let .heading(level, inline):
            let rung: ScaledFont = switch level {
            case 1: Typo.heading
            case 2: Typo.title
            default: Typo.bodyEmphasis
            }
            return styled(inline, rung: rung, scale: scale, face: face)
        case let .codeBlock(code, _, _):
            var result = AttributedString(code)
            result.font = Typo.code.resolved(scale: scale)
            result.foregroundColor = Palette.textPrimary
            result.backgroundColor = Palette.codeBackground
            return result
        case let .bulletList(items, _):
            return list(items, start: nil, scale: scale, face: face)
        case let .numberedList(start, items, _):
            return list(items, start: start, scale: scale, face: face)
        case let .taskList(items):
            var result = AttributedString()
            for (index, item) in items.enumerated() {
                if index > 0 { result += AttributedString("\n") }
                result += AttributedString(item.checked ? "☑  " : "☐  ")
                result += styled(item.inline, rung: Typo.body, scale: scale, face: face)
            }
            return result
        case let .blockQuote(quoted):
            return AttributedString("│  ") + blocks(quoted, scale: scale, face: face)
        case let .table(headers, rows, _):
            var result = tableRow(headers, scale: scale, face: face)
            for row in rows {
                result += AttributedString("\n")
                result += tableRow(row, scale: scale, face: face)
            }
            return result
        case .thematicBreak:
            return AttributedString("────────")
        }
    }

    private static func list(
        _ items: [[MarkdownBlock]], start: Int?, scale: CGFloat, face: ChatFont
    ) -> AttributedString {
        var result = AttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += AttributedString(start.map { "\($0 + index).  " } ?? "•  ")
            result += blocks(item, scale: scale, face: face, separator: "\n")
        }
        return result
    }

    private static func tableRow(
        _ cells: [[MarkdownInline]], scale: CGFloat, face: ChatFont
    ) -> AttributedString {
        var result = AttributedString()
        for (index, cell) in cells.enumerated() {
            if index > 0 { result += AttributedString("  │  ") }
            result += styled(cell, rung: Typo.body, scale: scale, face: face)
        }
        return result
    }

    private static func styled(
        _ inline: [MarkdownInline], rung: ScaledFont, scale: CGFloat, face: ChatFont
    ) -> AttributedString {
        InlineAttributes.render(
            inline, font: rung.resolved(scale: scale, face: face),
            code: rung.monospacedCompanion(scale: scale, face: face),
            color: Palette.textPrimary, intents: []
        )
    }
}
