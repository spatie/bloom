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
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.trailing, 4)
                    .padding(.bottom, 8)
            }
        }
        .background(isHovered ? Palette.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            Image(systemName: "sparkle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: TranscriptLayout.glyphWidth, alignment: .center)

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

            Spacer(minLength: 4)

            if tokens > 0 {
                Text("\(tokens) tokens")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
            }

            TranscriptDisclosure(isExpanded: isExpanded, isVisible: isHovered)
        }
        .padding(.horizontal, 6)
        .frame(height: Metrics.rowHeight)
    }
}

/// Shared geometry, so a thinking row, a tool row and a footer all land on the same columns. The
/// alignment is the point: it is what turns a list of events into something scannable.
enum TranscriptLayout {
    static let glyphWidth: CGFloat = 14
    static let glyphGap: CGFloat = 8
    static let labelWidth: CGFloat = 176
    /// Where an expanded body starts, lined up under the label column.
    static let detailIndent: CGFloat = glyphWidth + glyphGap + 6
    static let nestIndent: CGFloat = 16
}

/// The chevron only appears under the pointer. A column of them down a dense transcript reads as
/// noise, and the row is clickable anywhere regardless.
struct TranscriptDisclosure: View {
    var isExpanded: Bool
    var isVisible: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Palette.textTertiary)
            .frame(width: 10)
            .opacity(isVisible || isExpanded ? 1 : 0)
    }
}
