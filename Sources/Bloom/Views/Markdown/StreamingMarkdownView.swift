import AppKit
import SwiftUI
import BloomCore

/// A single text view can change its contents on every delta without changing the stack of
/// markdown blocks and native text views underneath SwiftUI's layout engine.
struct StreamingMarkdownView: View {
    let text: String
    @AppStorage(TranscriptLinkPreferences.key) private var allowedLinkSchemes = ""

    @Environment(\.fontScale) private var fontScale
    @Environment(\.chatFont) private var chatFont

    init(_ text: String) { self.text = text }

    @Environment(\.markdownProseMeasure) private var proseMeasure
    @Environment(\.chatLineHeight) private var lineHeight
    @Environment(\.markdownLinkActions) private var linkActions

    var body: some View {
        TranscriptTextView(
            text: NSAttributedString(string: ""),
            textAtWidth: { width in
                StreamingMarkdownText.native(
                    text, width: width, proseMeasure: proseMeasure, scale: fontScale,
                    face: chatFont, lineHeight: lineHeight,
                    allowedSchemes: TranscriptLinkPreferences.schemes(in: allowedLinkSchemes)
                )
            },
            linkColor: Palette.linkNSColor, actions: linkActions
        )
        // During handoff this prefix coexists with the saved answer's selectable blocks. The
        // transient copy must not register a second copy of the same answer for cross-row drags.
        .environment(\.transcriptConversationSelection, nil)
        .environment(\.transcriptTextSelection, nil)
    }
}

@MainActor
private enum StreamingMarkdownText {
    /// Only the current prefix is kept, so live deltas cannot evict settled Markdown caches.
    private static var nativeCache: (
        text: String, width: CGFloat, prose: CGFloat, scale: CGFloat, face: ChatFont,
        lineHeight: ChatLineHeight, allowedSchemes: Set<String>, rendered: NSAttributedString
    )?

    static func native(
        _ text: String, width: CGFloat, proseMeasure: CGFloat, scale: CGFloat,
        face: ChatFont, lineHeight: ChatLineHeight, allowedSchemes: Set<String>
    ) -> NSAttributedString {
        if let value = nativeCache, value.text == text, value.width == width,
           value.prose == proseMeasure, value.scale == scale, value.face == face,
           value.lineHeight == lineHeight, value.allowedSchemes == allowedSchemes {
            return value.rendered
        }
        let rendered = nativeBlocks(
            MarkdownParser.parse(text, allowedSchemes: allowedSchemes), width: width, proseMeasure: proseMeasure,
            scale: scale, face: face, lineHeight: lineHeight
        )
        nativeCache = (text, width, proseMeasure, scale, face, lineHeight, allowedSchemes, rendered)
        return rendered
    }

    private static func nativeBlocks(
        _ values: [MarkdownBlock], width: CGFloat, proseMeasure: CGFloat, scale: CGFloat,
        face: ChatFont, lineHeight: ChatLineHeight, separator: String = "\n\n"
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, value) in values.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: separator)) }
            switch value {
            case .bulletList(let items, _), .numberedList(_, let items, _):
                let start: Int? = if case .numberedList(let start, _, _) = value { start } else { nil }
                for (offset, item) in items.enumerated() {
                    if offset > 0 { result.append(NSAttributedString(string: "\n")) }
                    let body = nativeBlocks(item, width: width, proseMeasure: proseMeasure,
                        scale: scale, face: face, lineHeight: lineHeight, separator: "\n")
                    result.append(NSAttributedString(
                        string: start.map { "\($0 + offset).  " } ?? "•  ",
                        attributes: body.length > 0 ? body.attributes(at: 0, effectiveRange: nil) : nil
                    ))
                    result.append(body)
                }
            case .blockQuote(let quoted):
                let body = nativeBlocks(quoted, width: width, proseMeasure: proseMeasure,
                    scale: scale, face: face, lineHeight: lineHeight)
                result.append(NSAttributedString(string: "│  ",
                    attributes: body.length > 0 ? body.attributes(at: 0, effectiveRange: nil) : nil))
                result.append(body)
            default:
                let run = NSMutableAttributedString(attributedString: leaf(value, scale: scale, face: face))
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = TranscriptLayout.proseLeading(
                    Typo.body, scale: scale, face: face, lineHeight: lineHeight
                )
                // A positive tail indent is measured from the leading edge. TextKit therefore
                // gives paragraphs their own measure without splitting a live answer's view tree.
                if !value.needsFullChatColumn, proseMeasure.isFinite {
                    paragraph.tailIndent = min(max(1, width), proseMeasure)
                }
                run.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: run.length))
                result.append(run)
            }
        }
        let full = NSRange(location: 0, length: result.length)
        var missingFonts: [NSRange] = []
        result.enumerateAttribute(.font, in: full) { font, range, _ in
            if font == nil { missingFonts.append(range) }
        }
        for range in missingFonts {
            result.addAttribute(.font, value: Typo.body.resolvedNSFont(scale: scale, face: face), range: range)
            result.addAttribute(.foregroundColor, value: NSColor(Palette.textPrimary), range: range)
        }
        return result
    }

    private static func leaf(_ value: MarkdownBlock, scale: CGFloat, face: ChatFont) -> NSAttributedString {
        switch value {
        case .paragraph(let inline):
            return styled(inline, rung: Typo.body, scale: scale, face: face)
        case .heading(let level, let inline):
            let rung: ScaledFont = switch level {
            case 1: Typo.heading
            case 2: Typo.title
            default: Typo.bodyEmphasis
            }
            return styled(inline, rung: rung, scale: scale, face: face)
        case .codeBlock(let code, _, _):
            return NSAttributedString(string: code, attributes: [
                .font: Typo.code.resolvedNSFont(scale: scale),
                .foregroundColor: NSColor(Palette.textPrimary),
                .backgroundColor: NSColor(Palette.codeBackground),
            ])
        case .taskList(let items):
            let result = NSMutableAttributedString(string: "")
            for (index, item) in items.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: "\n")) }
                result.append(NSAttributedString(string: item.checked ? "☑  " : "☐  "))
                result.append(styled(item.inline, rung: Typo.body, scale: scale, face: face))
            }
            return result
        case .table(let headers, let rows, _):
            let result = NSMutableAttributedString(attributedString: tableRow(headers, scale: scale, face: face))
            for row in rows {
                result.append(NSAttributedString(string: "\n"))
                result.append(tableRow(row, scale: scale, face: face))
            }
            return result
        case .thematicBreak:
            return NSAttributedString(string: "────────")
        case .bulletList, .numberedList, .blockQuote:
            preconditionFailure("Nested blocks are rendered recursively before leaves")
        }
    }

    private static func tableRow(
        _ cells: [[MarkdownInline]], scale: CGFloat, face: ChatFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, cell) in cells.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  │  ")) }
            result.append(styled(cell, rung: Typo.body, scale: scale, face: face))
        }
        return result
    }

    private static func styled(
        _ inline: [MarkdownInline], rung: ScaledFont, scale: CGFloat, face: ChatFont
    ) -> NSAttributedString {
        InlineNSAttributes.make(
            inline, font: rung.resolvedNSFont(scale: scale, face: face),
            code: rung.monospacedCompanionNSFont(scale: scale, face: face),
            color: NSColor(Palette.textPrimary), lineSpacing: 0
        )
    }
}
