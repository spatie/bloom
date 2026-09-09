import SwiftUI
import BloomClient

/// One structural renderer for desktop and mobile. Inline text retains its platform behaviour.
public struct BloomMarkdownBlocks<Inline: View, Code: View>: View {
    private let blocks: [MarkdownBlock]
    private let style: BloomMarkdownStyle
    private let spacing: CGFloat?
    private let inline: ([MarkdownInline], BloomMarkdownInlineRole, Color, CGFloat?) -> Inline
    private let code: (String, Language) -> Code

    public init(
        blocks: [MarkdownBlock],
        style: BloomMarkdownStyle = BloomMarkdownStyle(),
        spacing: CGFloat? = nil,
        @ViewBuilder inline: @escaping ([MarkdownInline], BloomMarkdownInlineRole, Color, CGFloat?) -> Inline,
        @ViewBuilder code: @escaping (String, Language) -> Code
    ) {
        self.blocks = blocks
        self.style = style
        self.spacing = spacing
        self.inline = inline
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index], first: index == 0)
            }
        }
    }

    @ViewBuilder
    private func block(_ value: MarkdownBlock, first: Bool) -> some View {
        switch value {
        case let .paragraph(text):
            inline(text, .body, style.foreground, spacing)
        case let .heading(level, text):
            inline(text, .heading(level), style.foreground, spacing)
                .padding(.top, first ? 0 : 10)
                .accessibilityAddTraits(.isHeader)
        case let .codeBlock(text, language, _):
            code(text, language)
        case let .bulletList(items, tight):
            list(items, start: nil, tight: tight)
        case let .numberedList(start, items, tight):
            list(items, start: start, tight: tight)
        case let .taskList(items):
            VStack(alignment: .leading, spacing: style.taskGap) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: items[index].checked ? "checkmark.square.fill" : "square")
                            .font(style.markerFont)
                            .foregroundStyle(items[index].checked ? style.positive : style.tertiary)
                            .frame(width: style.markerWidth, alignment: .trailing)
                            .accessibilityLabel(items[index].checked ? "Done" : "Not done")
                        inline(items[index].inline, .body, style.foreground, style.taskLineSpacing)
                            .lineSpacing(style.taskLineSpacing)
                    }
                }
            }
        case let .blockQuote(children):
            HStack(alignment: .top, spacing: 8) {
                style.border.frame(width: 2).accessibilityHidden(true)
                nested(children, foreground: style.secondary, spacing: spacing)
            }
        case let .table(headers, rows, alignments):
            table(headers: headers, rows: rows, alignments: alignments)
        case .thematicBreak:
            rule
        }
    }

    private func nested(_ children: [MarkdownBlock], foreground: Color, spacing: CGFloat?) -> AnyView {
        var nestedStyle = style
        nestedStyle.foreground = foreground
        // Recursive markdown needs a finite view type. Erasure stays at the recursion boundary.
        return AnyView(Self(blocks: children, style: nestedStyle, spacing: spacing, inline: inline, code: code))
    }

    private func list(_ items: [[MarkdownBlock]], start: Int?, tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: tight ? style.tightListGap : style.looseListGap) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(start.map { "\($0 + index)." } ?? "\u{2022}")
                        .font(style.markerFont)
                        .foregroundStyle(style.secondary)
                        .monospacedDigit()
                        .frame(width: style.markerWidth, alignment: .trailing)
                    nested(items[index], foreground: style.foreground, spacing: style.proseListSpacing)
                        .lineSpacing(style.proseListSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [TableAlignment]) -> some View {
        if style.minimumTableColumnWidth > 0 {
            let minimumWidth = CGFloat(headers.count) * style.minimumTableColumnWidth
            ViewThatFits(in: .horizontal) {
                tableContents(headers: headers, rows: rows, alignments: alignments)
                    .frame(minWidth: minimumWidth)
                ScrollView(.horizontal) {
                    tableContents(headers: headers, rows: rows, alignments: alignments)
                        .frame(width: minimumWidth)
                }
            }
        } else {
            tableContents(headers: headers, rows: rows, alignments: alignments)
        }
    }

    private func tableContents(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [TableAlignment]) -> some View {
        BloomMarkdownTableLayout(columns: headers.count, minimumColumnWidth: style.minimumTableColumnWidth) {
            ForEach(headers.indices, id: \.self) { column in
                cell(headers[column], role: .tableHeader, alignment: alignment(column, alignments),
                     lastColumn: column == headers.count - 1, lastRow: rows.isEmpty)
                    .background(style.surface)
            }
            ForEach(rows.indices, id: \.self) { row in
                ForEach(rows[row].indices, id: \.self) { column in
                    cell(rows[row][column], role: .tableCell, alignment: alignment(column, alignments),
                         lastColumn: column == rows[row].count - 1, lastRow: row == rows.count - 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(style.border, lineWidth: 0.5) }
    }

    private func cell(
        _ text: [MarkdownInline], role: BloomMarkdownInlineRole, alignment: Alignment,
        lastColumn: Bool, lastRow: Bool
    ) -> some View {
        inline(text, role, style.foreground, spacing)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .overlay(alignment: .trailing) {
                if !lastColumn { style.border.frame(width: 1).accessibilityHidden(true) }
            }
            .overlay(alignment: .bottom) {
                if !lastRow { rule }
            }
    }

    private func alignment(_ column: Int, _ alignments: [TableAlignment]) -> Alignment {
        guard alignments.indices.contains(column) else { return .topLeading }
        return switch alignments[column] {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    private var rule: some View { style.border.frame(height: 1).accessibilityHidden(true) }
}
