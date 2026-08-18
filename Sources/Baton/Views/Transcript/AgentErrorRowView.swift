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
                        Rectangle()
                            .fill(Palette.negative)
                            .frame(width: TranscriptLayout.rule)
                    }
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.trailing, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.block)
            }
        }
        .modifier(ExpandableRow(isHovered: isHovered, isError: true))
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "exclamationmark.triangle", tint: Palette.negative)

            Text(status.map { "Agent exited (\($0))" } ?? "Agent error")
                .font(Typo.labelEmphasis)
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
