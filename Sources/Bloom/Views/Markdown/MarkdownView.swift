import SwiftUI
import AppKit
import BloomCore

/// A parsed answer, and everything derived from the parse that a caller would otherwise derive
/// again on every pass.
private final class MarkdownBlockBox: NSObject {
    let blocks: [MarkdownBlock]

    /// Every address the answer holds, in order and without repeats.
    ///
    /// Found once, here, because `LinkPolicy.addresses(in:)` walks the whole block tree and every
    /// inline run inside it, and `MarkdownView.body` asked for it in front of blocks that were
    /// already cached: the parse was kept and the walk over its result was not, so a settled row
    /// paid for it on every pass of the transcript's list. It is a pure function of the blocks, and
    /// the blocks are what this box exists to hold.
    let addresses: [String]

    init(_ blocks: [MarkdownBlock], addresses: [String]) {
        self.blocks = blocks
        self.addresses = addresses
    }

    convenience init(_ blocks: [MarkdownBlock]) {
        self.init(blocks, addresses: LinkPolicy.addresses(in: blocks))
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

    static func parsed(for text: String) -> MarkdownBlockBox {
        let key = text as NSString
        if let cached = values.object(forKey: key) { return cached }
        let box = MarkdownBlockBox(MarkdownParser.parse(text))
        values.setObject(box, forKey: key, cost: text.utf8.count)
        return box
    }

    /// The live tail gets a cache of exactly one entry rather than a share of the one above.
    ///
    /// Streaming an answer produces one prefix per token, every one of them seen for a few
    /// milliseconds and never again. Put through `values`, which holds 160 entries, a single
    /// streamed answer would evict every finished row in it and leave the visible transcript
    /// re-parsing settled prose on its next redraw. One entry is still worth keeping, because
    /// SwiftUI is free to evaluate a body more than once for the same value.
    ///
    /// The addresses in this one are always empty, and that is not an omission: a run that is
    /// still arriving offers none, so there is nothing for the walk to find and nothing yet worth
    /// finding. See `MarkdownView.body`.
    private static var streamed: (text: String, box: MarkdownBlockBox)?

    static func streamingParsed(for text: String) -> MarkdownBlockBox {
        if let streamed, streamed.text == text { return streamed.box }
        let box = MarkdownBlockBox(MarkdownParser.parse(text), addresses: [])
        streamed = (text, box)
        return box
    }
}

/// Agent prose needs structural rendering and a parse cache because transcript rows update while streaming.
public struct MarkdownView: View {
    private let text: String
    private let isStreaming: Bool

    /// - Parameter isStreaming: whether this text is still being written. It changes nothing about
    ///   what is drawn, only which cache the parse goes through. See
    ///   `MarkdownParseCache.streamingParsed(for:)`.
    public init(_ text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    public var body: some View {
        // Which addresses may be opened, and which may not, is `LinkPolicy.opens`. It is not
        // a rule about this view: the user's own bubble is drawn by a different one and goes
        // through the same door. The walk that finds them happens where the parse does, so a
        // settled answer pays for neither twice. See `MarkdownBlockBox.addresses`.
        //
        // Not while it is still being written. A menu rebuilt on every token would be work done
        // for a reader who is not there yet, and there is nothing to copy until the sentence
        // carrying the address has finished arriving, so the streaming slot holds none.
        let parsed = isStreaming
            ? MarkdownParseCache.streamingParsed(for: text)
            : MarkdownParseCache.parsed(for: text)
        MarkdownBlocksView(blocks: parsed.blocks)
            .environment(\.markdownIsStreaming, isStreaming)
            .opensTranscriptLinks()
            .transcriptLinkMenu(parsed.addresses)
            .transcriptLinkActions(parsed.addresses)
    }
}

/// Whether the answer these blocks belong to is still arriving, and what to do with a link in
/// them. Both are the enclosing `MarkdownView`'s to know, and both are needed several levels down
/// inside a quote, a list or a table cell, so they travel as environment rather than as arguments
/// threaded through every recursion.
extension View {
    /// What every markdown row below this point does with a link.
    ///
    /// Set once, by the view that knows which workspace the transcript belongs to, rather than
    /// per row. That alone was not enough: the value is built in a computed property, so it is a
    /// fresh struct every pass, and a struct of closures cannot be compared. See
    /// `TranscriptLinkActions`, which is `Equatable` on its identity for this reason.
    func markdownLinkActions(_ actions: TranscriptLinkActions) -> some View {
        environment(\.markdownLinkActions, actions)
    }
}

extension EnvironmentValues {
    @Entry var markdownIsStreaming: Bool = false
    @Entry var markdownLinkActions = TranscriptLinkActions()
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var foreground = Palette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownMetrics.blockGap) {
            // Over the indices rather than over `Array(blocks.enumerated())`, which allocates a
            // second array of pairs every pass to draw the same blocks. The same change is made
            // everywhere below it, and the identity is what it always was: a block's position.
            ForEach(blocks.indices, id: \.self) { offset in
                MarkdownBlockView(block: blocks[offset], foreground: foreground, isFirst: offset == 0)
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
    @Environment(\.markdownIsStreaming) private var isStreaming
    @Environment(\.markdownLinkActions) private var linkActions

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
    /// One run of inline markdown, drawn by whichever of the two renderers this run needs.
    ///
    /// **`Text` unless there is a link in it.** An `NSTextView` is what makes a link behave like
    /// one, and it is also the more expensive of the two: it holds a layout manager and a text
    /// storage, and handing it a new string relays the whole run out. Most paragraphs in most
    /// answers hold no address at all, and those keep the renderer they have always had, with the
    /// attributed string cache in front of it.
    ///
    /// **And never while the answer is still arriving.** `4088ecd` established that a streamed
    /// answer is re-rendered on every delta, and rebuilding an attributed string and relaying out
    /// a text view per token is quadratic over the length of the answer. A link is not pressable
    /// for the second or two its sentence is being written, and it becomes pressable the moment
    /// the turn settles, which nobody will ever notice.
    @ViewBuilder
    private func inlineText(_ inline: [MarkdownInline], rung: ScaledFont, color: Color) -> some View {
        let font = rung.resolved(scale: fontScale, face: chatFont)
        if !isStreaming, InlineNSAttributes.hasLink(inline) {
            TranscriptTextView(
                text: InlineNSAttributes.make(
                    inline,
                    font: rung.resolvedNSFont(scale: fontScale, face: chatFont),
                    code: rung.monospacedCompanionNSFont(scale: fontScale, face: chatFont),
                    color: NSColor(color),
                    lineSpacing: TranscriptLayout.proseLeading
                ),
                linkColor: Palette.linkNSColor,
                selectionColor: .selectedTextBackgroundColor,
                actions: linkActions
            )
        } else {
            Text(InlineAttributes.make(
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
            ForEach(items.indices, id: \.self) { offset in
                // Baseline, not top: this is the alignment the task list beside it already used,
                // and top alignment sat the marker a fraction above the line it marks.
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                    marker(start.map { "\($0 + offset)." } ?? "\u{2022}")
                    MarkdownBlocksView(blocks: items[offset], foreground: foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func taskList(_ items: [(checked: Bool, inline: [MarkdownInline])]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
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
                    ForEach(headers.indices, id: \.self) { column in
                        // A header set a rung below the cells under it was the wrong way round.
                        // Same size, heavier, on a fill: that is what makes it read as a header.
                        tableCell(
                            headers[column],
                            rung: Typo.bodyEmphasis,
                            alignment: alignment(at: column, in: alignments),
                            isLastColumn: column == headers.count - 1,
                            isLastRow: false
                        )
                        .background(Palette.surfaceSunken)
                    }
                }
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    GridRow {
                        ForEach(row.indices, id: \.self) { column in
                            tableCell(
                                row[column],
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

/// The same inline tree as an `NSAttributedString`, for the rows that hold a link.
///
/// A twin of `InlineAttributes` rather than a conversion of it. A SwiftUI `AttributedString`
/// carries `Font` and `Color`, which are descriptions the renderer resolves and cannot be read
/// back out, so the AppKit side has to be built from the tree with real faces and real colours.
/// The two walk the same cases in the same order for that reason.
///
/// Links get the `.link` attribute and nothing else: their colour comes from the text view's
/// `linkTextAttributes` and their underline appears only under the pointer. See
/// `TranscriptTextView`.
@MainActor
enum InlineNSAttributes {
    static func make(
        _ inline: [MarkdownInline],
        font: NSFont,
        code: NSFont,
        color: NSColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let output = NSMutableAttributedString()
        render(inline, font: font, code: code, color: color, traits: [], into: output)
        output.addAttribute(
            .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length)
        )
        return output
    }

    private static func render(
        _ values: [MarkdownInline],
        font: NSFont,
        code: NSFont,
        color: NSColor,
        traits: NSFontTraitMask,
        into output: NSMutableAttributedString
    ) {
        for value in values {
            switch value {
            case let .text(text):
                output.append(run(text, font: faced(font, traits), color: color))
            case let .emphasis(children):
                render(children, font: font, code: code, color: color, traits: traits.union(.italicFontMask), into: output)
            case let .strong(children):
                render(children, font: font, code: code, color: color, traits: traits.union(.boldFontMask), into: output)
            case let .strikethrough(children):
                let start = output.length
                render(children, font: font, code: code, color: color, traits: traits, into: output)
                output.addAttribute(
                    .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: start, length: output.length - start)
                )
            case let .code(text):
                let child = run(text, font: faced(code, traits), color: color)
                child.addAttribute(
                    .backgroundColor, value: Palette.hoverNSColor,
                    range: NSRange(location: 0, length: child.length)
                )
                output.append(child)
            case let .link(text, url):
                let start = output.length
                render(text, font: font, code: code, color: color, traits: traits, into: output)
                if let target = URL(string: url), LinkPolicy.opens(target) {
                    output.addAttribute(
                        .link, value: target,
                        range: NSRange(location: start, length: output.length - start)
                    )
                }
            case .lineBreak:
                output.append(run("\n", font: faced(font, traits), color: color))
            }
        }
    }

    private static func run(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    /// Bold and italic asked of the font manager rather than of a descriptor, because a face that
    /// has no italic gets an oblique this way instead of silently staying upright.
    private static func faced(_ font: NSFont, _ traits: NSFontTraitMask) -> NSFont {
        guard !traits.isEmpty else { return font }
        return NSFontManager.shared.convert(font, toHaveTrait: traits)
    }

    /// Whether this run holds anything worth an `NSTextView`.
    static func hasLink(_ values: [MarkdownInline]) -> Bool {
        values.contains { value in
            switch value {
            case .link: true
            case let .emphasis(children), let .strong(children), let .strikethrough(children):
                hasLink(children)
            case .text, .code, .lineBreak: false
            }
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
        cachedHash = Self.hash(of: inline, font: font, code: code, color: color)
    }

    /// **A weak hash, on purpose, and the equality below is unchanged.**
    ///
    /// This was `hasher.combine(inline)`, which walks the recursive tree and SipHashes every string
    /// in it, so looking a cached paragraph up cost a pass over the whole paragraph. What it was
    /// guarding is `isEqual`'s `inline == other.inline`, and that comparison almost never walks
    /// anything: the blocks come out of `MarkdownParseCache`, so both sides are the same array
    /// buffer and `Array.==` answers on identity alone. The lookup was paying the full price of the
    /// comparison it exists to avoid.
    ///
    /// So the hash is the paragraph's shape rather than its contents: how many runs it has, what
    /// the first and last of them are, and the presentation. Two paragraphs that agree on all of
    /// that land in one bucket and are told apart by `isEqual`, which is exact. A weaker hash can
    /// only cost bucket collisions; it cannot return the wrong string.
    private static func hash(of inline: [MarkdownInline], font: Font, code: Font, color: Color) -> Int {
        var hasher = Hasher()
        hasher.combine(inline.count)
        if let first = inline.first { combine(first, into: &hasher) }
        if let last = inline.last, inline.count > 1 { combine(last, into: &hasher) }
        hasher.combine(font)
        hasher.combine(code)
        hasher.combine(color)
        return hasher.finalize()
    }

    /// How much of a run's text is looked at. Long enough that two paragraphs opening on the same
    /// few words are still told apart, short enough that the walk is bounded.
    private static let sample = 24

    /// One run, as a case tag and a bounded amount of what is in it.
    private static func combine(_ value: MarkdownInline, into hasher: inout Hasher) {
        switch value {
        case let .text(text):
            hasher.combine(0)
            hasher.combine(text.utf8.count)
            hasher.combine(text.prefix(sample))
        case let .code(text):
            hasher.combine(1)
            hasher.combine(text.utf8.count)
            hasher.combine(text.prefix(sample))
        case let .emphasis(children):
            hasher.combine(2)
            hasher.combine(children.count)
        case let .strong(children):
            hasher.combine(3)
            hasher.combine(children.count)
        case let .strikethrough(children):
            hasher.combine(4)
            hasher.combine(children.count)
        case let .link(text, url):
            hasher.combine(5)
            hasher.combine(text.count)
            hasher.combine(url.utf8.count)
            hasher.combine(url.prefix(sample))
        case .lineBreak:
            hasher.combine(6)
        }
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
                // The same `opens` gate as the AppKit twin above, styling included: without it a
                // streaming row drew a scheme the app refuses as a live blue link that did
                // nothing when clicked, then flipped to plain text as the row settled, which is
                // the settle-jump this renderer pair exists to prevent.
                if let target = URL(string: url), LinkPolicy.opens(target) {
                    var child = render(text, font: font, code: code, color: Palette.link, intents: intents)
                    child.foregroundColor = Palette.link
                    child.underlineStyle = .single
                    child.link = target
                    output += child
                } else {
                    output += render(text, font: font, code: code, color: color, intents: intents)
                }
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
