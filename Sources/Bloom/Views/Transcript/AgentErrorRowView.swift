import SwiftUI

/// The agent stopped in a way it did not choose. One line, with the whole of stderr behind it.
struct AgentErrorRowView: View {
    var stderr: String
    var status: Int?
    var isExpanded: Bool
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRowHeader(isExpanded: isExpanded, onToggle: onToggle) {
                header
            }

            if isExpanded, !stderr.isEmpty {
                Text(stderr)
                    .font(Typo.code)
                    .foregroundStyle(Palette.negative)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TranscriptLayout.block)
                    .overlay(alignment: .leading) {
                        // The quote mark for the block, in the colour every quote rule in the
                        // transcript uses. The text inside it is already the alarm colour.
                        Rectangle()
                            .fill(Palette.border)
                            .frame(width: TranscriptLayout.rule)
                    }
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.trailing, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.block)
            }
        }
        .modifier(ExpandableRow(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "exclamationmark.triangle", tint: Palette.negative)

            Text(status.map { "Agent exited (\($0))" } ?? "Agent error")
                .font(Typo.label)
                .foregroundStyle(Palette.negative)
                .lineLimit(1)
                .truncationMode(.tail)
                .transcriptLabelColumn()

            Text(ToolPresenter.oneLine(stderr))
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: TranscriptLayout.tight)

            TranscriptDisclosure(isExpanded: isExpanded, isVisible: isHovered)
        }
        .transcriptRowFrame()
    }
}
