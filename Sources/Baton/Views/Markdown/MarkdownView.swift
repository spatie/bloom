import SwiftUI
import AppKit

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
}

/// Agent prose needs structural rendering and a parse cache because transcript rows update while streaming.
public struct MarkdownView: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        MarkdownBlocksView(blocks: MarkdownParseCache.blocks(for: text))
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var foreground = Palette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, foreground: foreground)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let foreground: Color

    @ViewBuilder
    var body: some View {
        switch block {
        case let .paragraph(inline):
            inlineText(inline, font: Typo.body, color: foreground)
                .lineSpacing(3)
        case let .heading(level, inline):
            inlineText(inline, font: level <= 2 ? Typo.title : Typo.bodyEmphasis, color: foreground)
                .padding(.top, level <= 2 ? Metrics.gutter : Metrics.corner)
        case let .codeBlock(code, language, _):
            CodeBlockView(code: code, language: language)
        case let .bulletList(items, tight):
            list(items: items, start: nil, tight: tight)
        case let .numberedList(start, items, tight):
            list(items: items, start: start, tight: tight)
        case let .taskList(items):
            taskList(items)
        case let .blockQuote(blocks):
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Palette.border)
                    .frame(width: 2)
                MarkdownBlocksView(blocks: blocks, foreground: Palette.textSecondary)
                    .padding(.leading, 10)
            }
        case let .table(headers, rows, alignments):
            table(headers: headers, rows: rows, alignments: alignments)
        case .thematicBreak:
            Hairline()
        }
    }

    private func inlineText(_ inline: [MarkdownInline], font: Font, color: Color) -> some View {
        Text(InlineAttributes.make(inline, font: font, color: color))
            .font(font)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func marker(_ text: String?, bullet: Bool) -> some View {
        Group {
            if bullet {
                Circle()
                    .fill(Palette.textTertiary)
                    .frame(width: Metrics.cornerSmall, height: Metrics.cornerSmall)
                    .padding(.top, Metrics.corner)
            } else if let text {
                Text(text)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
            }
        }
        .frame(width: 18, alignment: .trailing)
    }

    private func list(items: [[MarkdownBlock]], start: Int?, tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: tight ? 0 : Metrics.cornerSmall) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .top, spacing: 0) {
                    marker(start.map { "\($0 + offset)." }, bullet: start == nil)
                    MarkdownBlocksView(blocks: item, foreground: foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func taskList(_ items: [(checked: Bool, inline: [MarkdownInline])]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                        .font(Typo.caption)
                        .foregroundStyle(item.checked ? Palette.accent : Palette.textTertiary)
                        .frame(width: 18, alignment: .trailing)
                    inlineText(item.inline, font: Typo.body, color: foreground)
                }
            }
        }
    }

    private func table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [TableAlignment]) -> some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { column, header in
                        tableCell(header, font: Typo.labelEmphasis, alignment: alignment(at: column, in: alignments))
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            tableCell(cell, font: Typo.body, alignment: alignment(at: column, in: alignments))
                        }
                    }
                }
            }
            .overlay {
                Rectangle().stroke(Palette.border, lineWidth: Metrics.hairline)
            }
        }
    }

    private func tableCell(_ inline: [MarkdownInline], font: Font, alignment: Alignment) -> some View {
        inlineText(inline, font: font, color: foreground)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.corner)
            .frame(maxWidth: .infinity, alignment: alignment)
            .overlay(alignment: .trailing) {
                Hairline(axis: .vertical)
            }
            .overlay(alignment: .bottom) {
                Hairline()
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

private enum InlineAttributes {
    static func make(_ inline: [MarkdownInline], font: Font, color: Color) -> AttributedString {
        render(inline, font: font, color: color, intents: [])
    }

    private static func render(
        _ values: [MarkdownInline],
        font: Font,
        color: Color,
        intents: InlinePresentationIntent
    ) -> AttributedString {
        var output = AttributedString()
        for value in values {
            switch value {
            case let .text(text):
                output += run(text, font: font, color: color, intents: intents)
            case let .emphasis(children):
                output += render(children, font: font, color: color, intents: intents.union(.emphasized))
            case let .strong(children):
                output += render(children, font: font, color: color, intents: intents.union(.stronglyEmphasized))
            case let .strikethrough(children):
                var child = render(children, font: font, color: color, intents: intents)
                child.strikethroughStyle = .single
                output += child
            case let .code(code):
                var child = AttributedString(code)
                child.font = Typo.code
                child.foregroundColor = Palette.textPrimary
                child.backgroundColor = Palette.surfaceSunken
                output += child
            case let .link(text, url):
                var child = render(text, font: font, color: Palette.accent, intents: intents)
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
