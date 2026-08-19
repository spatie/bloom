import SwiftUI
import AppKit
import BloomCore

private final class MarkdownBlockBox: NSObject {
    let blocks: [MarkdownBlock]

    init(_ blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }
}

@MainActor
private enum MarkdownParseCache {
    static let values: NSCache<NSString, MarkdownBlockBox> = {
        let cache = NSCache<NSString, MarkdownBlockBox>()
        cache.countLimit = 160
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    static func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let cached = values.object(forKey: key) { return cached.blocks }
        let blocks = MarkdownParser.parse(text)
        values.setObject(MarkdownBlockBox(blocks), forKey: key, cost: text.utf8.count)
        return blocks
    }

    /// The live tail gets a cache of exactly one entry rather than a share of the one above.
    ///
    /// Streaming an answer produces one prefix per token, every one of them seen for a few
    /// milliseconds and never again. Put through `values`, which holds 160 entries, a single
    /// streamed answer would evict every finished row in it and leave the visible transcript
    /// re-parsing settled prose on its next redraw. One entry is still worth keeping, because
    /// SwiftUI is free to evaluate a body more than once for the same value.
    private static var streamed: (text: String, blocks: [MarkdownBlock])?

    static func streamingBlocks(for text: String) -> [MarkdownBlock] {
        if let streamed, streamed.text == text { return streamed.blocks }
        let blocks = MarkdownParser.parse(text)
        streamed = (text, blocks)
        return blocks
    }
}

/// Agent prose needs structural rendering and a parse cache because transcript rows update while streaming.
public struct MarkdownView: View {
    private let text: String
    private let isStreaming: Bool

    /// - Parameter isStreaming: whether this text is still being written. It changes nothing about
    ///   what is drawn, only which cache the parse goes through. See
    ///   `MarkdownParseCache.streamingBlocks(for:)`.
    public init(_ text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    public var body: some View {
        MarkdownBlocksView(blocks: isStreaming
            ? MarkdownParseCache.streamingBlocks(for: text)
            : MarkdownParseCache.blocks(for: text))
            .environment(\.openURL, OpenURLAction { url in
                // Only a web address or a mail address is handed to the system. Everything drawn
                // here was written by an agent, and `[text](url)` puts whatever it likes in the
                // target: `file:///Applications/...` or a private scheme registered by some other
                // app would otherwise launch that thing on a click in a transcript. The bare and
                // angle bracketed forms the parser recognises are already http(s) only; this is
                // the one that is not.
                guard let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http" || scheme == "mailto" else {
                    return .discarded
                }
                NSWorkspace.shared.open(url)
                return .handled
            })
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var foreground = Palette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownMetrics.blockGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                MarkdownBlockView(block: block, foreground: foreground, isFirst: offset == 0)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let foreground: Color
    /// A heading only claims space above it when there is something above it to be separated from.
    var isFirst = false

    /// The marker column follows the conversation's text size, otherwise a raised body size pushes
    /// "10." straight out of a column sized for the default one. This was a `@ScaledMetric`, which
    /// on macOS never moves: there is no Dynamic Type for it to track.
    @Environment(\.fontScale) private var fontScale
    /// The conversation's face, for the same reason: prose set in it, inline code paired to it.
    @Environment(\.chatFont) private var chatFont

    private var markerWidth: CGFloat { MarkdownMetrics.markerWidth * fontScale }

    @ViewBuilder
    var body: some View {
        switch block {
        case let .paragraph(inline):
            inlineText(inline, rung: Typo.body, color: foreground)
        case let .heading(level, inline):
            // Three real steps rather than one. Every level used to land on reading size and
            // differ only in weight, so an agent that structured its answer with headings got a
            // wall of bold sentences and no structure at all.
            inlineText(inline, rung: Self.headingFont(level), color: foreground)
                .padding(.top, isFirst ? 0 : MarkdownMetrics.headingLead)
        case let .codeBlock(code, language, _):
            CodeBlockView(code: code, language: language)
        case let .bulletList(items, tight):
            list(items: items, start: nil, tight: tight)
        case let .numberedList(start, items, tight):
            list(items: items, start: start, tight: tight)
        case let .taskList(items):
            taskList(items)
        case let .blockQuote(blocks):
            HStack(alignment: .top, spacing: TranscriptLayout.block) {
                Rectangle()
                    .fill(Palette.border)
                    .frame(width: TranscriptLayout.rule)
                MarkdownBlocksView(blocks: blocks, foreground: Palette.textSecondary)
            }
        case let .table(headers, rows, alignments):
            table(headers: headers, rows: rows, alignments: alignments)
        case .thematicBreak:
            Hairline()
        }
    }

    private static func headingFont(_ level: Int) -> ScaledFont {
        switch level {
        case 1: Typo.heading
        case 2: Typo.title
        default: Typo.bodyEmphasis
        }
    }

    /// An attributed string needs a real `Font`, so the rung is resolved here rather than left to
    /// the `.font(ScaledFont)` modifier the rest of the app leans on. The rung is carried this far
    /// rather than a `Font`, because the code face has to be derived from the same rung: a span of
    /// code takes its size from the run it sits in, not from a rung of its own.
    private func inlineText(_ inline: [MarkdownInline], rung: ScaledFont, color: Color) -> some View {
        let font = rung.resolved(scale: fontScale, face: chatFont)
        return Text(InlineAttributes.make(
            inline,
            font: font,
            code: rung.monospacedCompanion(scale: fontScale, face: chatFont),
            color: color
        ))
        .font(font)
        .foregroundStyle(color)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func marker(_ text: String) -> some View {
        Text(text)
            .font(Typo.body)
            // Tertiary is the shade a disabled control gets. A bullet is quiet, not switched off,
            // and at a quarter ink it all but vanished against the line it belongs to.
            .foregroundStyle(Palette.textSecondary)
            .monospacedDigit()
            .frame(width: markerWidth, alignment: .trailing)
    }

    private func list(items: [[MarkdownBlock]], start: Int?, tight: Bool) -> some View {
        // A tight list at zero read as one paragraph with dots in it, and a loose one at four was
        // tighter than the gap between the marker and its own text.
        VStack(alignment: .leading, spacing: tight ? Metrics.spacingTight : Metrics.spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                // Baseline, not top: this is the alignment the task list beside it already used,
                // and top alignment sat the marker a fraction above the line it marks.
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                    marker(start.map { "\($0 + offset)." } ?? "\u{2022}")
                    MarkdownBlocksView(blocks: item, foreground: foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func taskList(_ items: [(checked: Bool, inline: [MarkdownInline])]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                    Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                        .font(Typo.body)
                        .foregroundStyle(item.checked ? Palette.positive : Palette.textTertiary)
                        .frame(width: markerWidth, alignment: .trailing)
                        .accessibilityLabel(item.checked ? "Done" : "Not done")
                    inlineText(item.inline, rung: Typo.body, color: foreground)
                }
            }
        }
    }

    private func table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [TableAlignment]) -> some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { column, header in
                        // A header set a rung below the cells under it was the wrong way round.
                        // Same size, heavier, on a fill: that is what makes it read as a header.
                        tableCell(
                            header,
                            rung: Typo.bodyEmphasis,
                            alignment: alignment(at: column, in: alignments),
                            isLastColumn: column == headers.count - 1,
                            isLastRow: false
                        )
                        .background(Palette.surfaceSunken)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            tableCell(
                                cell,
                                rung: Typo.body,
                                alignment: alignment(at: column, in: alignments),
                                isLastColumn: column == row.count - 1,
                                isLastRow: index == rows.count - 1
                            )
                        }
                    }
                }
            }
            // Clipped before it is stroked, so the header fill stops at the corner and the last
            // column and row do not draw a second line under the border they already have.
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
            }
        }
    }

    private func tableCell(
        _ inline: [MarkdownInline],
        rung: ScaledFont,
        alignment: Alignment,
        isLastColumn: Bool,
        isLastRow: Bool
    ) -> some View {
        inlineText(inline, rung: rung, color: foreground)
            .padding(.horizontal, MarkdownMetrics.blockGap)
            .padding(.vertical, Metrics.spacing)
            .frame(maxWidth: .infinity, alignment: alignment)
            .overlay(alignment: .trailing) {
                if !isLastColumn { Hairline(axis: .vertical) }
            }
            .overlay(alignment: .bottom) {
                if !isLastRow { Hairline() }
            }
    }

    private func alignment(at index: Int, in alignments: [TableAlignment]) -> Alignment {
        guard alignments.indices.contains(index) else { return .leading }
        return switch alignments[index] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private final class InlineAttributesKey: NSObject {
    let inline: [MarkdownInline]
    let font: Font
    let code: Font
    let color: Color
    private let cachedHash: Int

    init(inline: [MarkdownInline], font: Font, code: Font, color: Color) {
        self.inline = inline
        self.font = font
        self.code = code
        self.color = color
        var hasher = Hasher()
        hasher.combine(inline)
        hasher.combine(font)
        hasher.combine(code)
        hasher.combine(color)
        cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? InlineAttributesKey else { return false }
        return cachedHash == other.cachedHash
            && inline == other.inline
            && font == other.font
            && code == other.code
            && color == other.color
    }
}

private final class InlineAttributesBox {
    let value: AttributedString

    init(_ value: AttributedString) { self.value = value }
}

/// Keeps parsed paragraphs from rebuilding the same styled string on unrelated view updates.
///
/// Inline runs, both fonts and the foreground colour all participate in exact equality so a
/// cached value cannot cross between structurally equal text rendered with different presentation,
/// which now includes the same paragraph seen in two different conversation faces.
@MainActor
private enum InlineAttributes {
    private static let values: NSCache<InlineAttributesKey, InlineAttributesBox> = {
        let cache = NSCache<InlineAttributesKey, InlineAttributesBox>()
        cache.countLimit = 1_000
        return cache
    }()

    static func make(
        _ inline: [MarkdownInline],
        font: Font,
        code: Font,
        color: Color
    ) -> AttributedString {
        let key = InlineAttributesKey(inline: inline, font: font, code: code, color: color)
        if let cached = values.object(forKey: key) { return cached.value }

        let value = render(inline, font: font, code: code, color: color, intents: [])
        values.setObject(InlineAttributesBox(value), forKey: key)
        return value
    }

    private static func render(
        _ values: [MarkdownInline],
        font: Font,
        code: Font,
        color: Color,
        intents: InlinePresentationIntent
    ) -> AttributedString {
        var output = AttributedString()
        for value in values {
            switch value {
            case let .text(text):
                output += run(text, font: font, color: color, intents: intents)
            case let .emphasis(children):
                output += render(children, font: font, code: code, color: color, intents: intents.union(.emphasized))
            case let .strong(children):
                output += render(children, font: font, code: code, color: color, intents: intents.union(.stronglyEmphasized))
            case let .strikethrough(children):
                var child = render(children, font: font, code: code, color: color, intents: intents)
                child.strikethroughStyle = .single
                output += child
            case let .code(text):
                var child = AttributedString(text)
                // Derived from the run it sits in rather than pinned to `Typo.code`, and carrying
                // whatever emphasis is around it. Pinned, a span of code dropped a rung inside a
                // paragraph and two inside a heading, took the primary colour inside a quote that
                // was set secondary, and stayed upright inside bold and italic.
                child.font = code
                child.foregroundColor = color
                child.backgroundColor = Palette.hover
                if !intents.isEmpty { child.inlinePresentationIntent = intents }
                output += child
            case let .link(text, url):
                var child = render(text, font: font, code: code, color: Palette.accent, intents: intents)
                child.foregroundColor = Palette.accent
                child.underlineStyle = .single
                if let target = URL(string: url) { child.link = target }
                output += child
            case .lineBreak:
                output += run("\n", font: font, color: color, intents: intents)
            }
        }
        return output
    }

    private static func run(_ text: String, font: Font, color: Color, intents: InlinePresentationIntent) -> AttributedString {
        var value = AttributedString(text)
        value.font = font
        value.foregroundColor = color
        if !intents.isEmpty { value.inlinePresentationIntent = intents }
        return value
    }
}
