import SwiftUI

/// A thinking block, which is worth showing and almost never worth reading in full.
///
/// Collapsed it is one dimmed italic line, the same height as every tool row, so a turn that
/// thought six times still scans as six lines. Expanded it is the whole reasoning trace, which is
/// occasionally exactly what the user needs when an agent has gone somewhere strange.
struct ThinkingRowView: View {
    var text: String
    var isExpanded = false
    var tokens: Int = 0
    var onToggle: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded, !text.isEmpty {
                Text(text)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(TranscriptLayout.proseLeading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.trailing, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .rowBackground(isSelected: false, isHovered: isHovered)
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "sparkle", tint: Palette.textTertiary)

            Text("Thinking")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .italic()
                .lineLimit(1)
                .frame(width: TranscriptLayout.labelWidth, alignment: .leading)

            if !isExpanded {
                Text(ToolPresenter.oneLine(text))
                    .font(Typo.label)
                    .foregroundStyle(Palette.textTertiary)
                    .italic()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: TranscriptLayout.tight)

            if tokens > 0 {
                Text("\(tokens) tokens")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
            }

            TranscriptDisclosure(isExpanded: isExpanded, isVisible: isHovered)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .frame(height: Metrics.rowHeight)
    }
}

/// Shared geometry, so a thinking row, a tool row and a footer all land on the same columns. The
/// alignment is the point: it is what turns a list of events into something scannable.
///
/// There is one scale here rather than a literal at every call site, because a transcript that
/// streams new rows in is only calm if every row type agrees on where its columns start.
enum TranscriptLayout {
    /// The gap between two things that belong to each other, such as a label and its counter.
    static let tight: CGFloat = 2
    /// The inset every row keeps from the edge of the pane, and the general gap between pieces.
    static let inset: CGFloat = 6
    /// Between stacked blocks inside an expanded row.
    static let block: CGFloat = 8

    static let glyphWidth: CGFloat = 16
    static let glyphGap: CGFloat = 8
    static let labelWidth: CGFloat = 176
    /// Where an expanded body starts, lined up under the label column.
    static let detailIndent: CGFloat = glyphWidth + glyphGap + inset
    static let nestIndent: CGFloat = 16
    /// The coloured rule down the left of an error, a quote or a tool result.
    static let rule: CGFloat = 2
    static let disclosureWidth: CGFloat = 10
    /// Extra leading for the two places that render real prose rather than one line.
    static let proseLeading: CGFloat = 3
}

/// The leading glyph of any row.
///
/// It exists so every row type draws its symbol at one size, in one column width. Symbols have
/// wildly different intrinsic widths, and letting each row pick its own point size is what makes
/// a dense list look ragged down its left edge.
struct TranscriptGlyph: View {
    var symbol: String
    var tint: Color = Palette.textTertiary

    var body: some View {
        Image(systemName: symbol)
            .font(Typo.label)
            .imageScale(.small)
            .foregroundStyle(tint)
            .frame(width: TranscriptLayout.glyphWidth, alignment: .center)
    }
}

/// The chevron only appears under the pointer. A column of them down a dense transcript reads as
/// noise, and the row is clickable anywhere regardless.
struct TranscriptDisclosure: View {
    var isExpanded: Bool
    var isVisible: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(Typo.micro)
            .imageScale(.small)
            .foregroundStyle(Palette.textTertiary)
            .frame(width: TranscriptLayout.disclosureWidth)
            .opacity(isVisible || isExpanded ? 1 : 0)
    }
}
