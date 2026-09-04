import BloomCore
import SwiftUI

/// The one line that stands for a turn's working.
///
/// The disclosure, count and noun keep the same geometry in both states. The commands belong
/// inside the disclosure, so the collapsed line never promotes one arbitrary command to a title.
struct TranscriptFoldRowView: View {
    var hiddenCount: Int
    var showsMore: Bool
    var isExpanded: Bool
    /// Whether this stands for a subagent's own work, in which case it is drawn where those rows
    /// are drawn: indented under the call that started them, behind the same rule. A line at the
    /// margin standing for indented rows reads as work the main agent did.
    var isNested = false
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        ExpandableRowHeader(isExpanded: isExpanded, onToggle: onToggle) {
            HStack(spacing: Metrics.spacingSmall) {
                TranscriptDisclosure(isExpanded: isExpanded, isVisible: true)
                    .frame(width: TranscriptLayout.disclosureWidth)

                HStack(spacing: TranscriptLayout.glyphGap) {
                    TranscriptGlyph(symbol: "circle")
                        .environment(\.transcriptFoldCount, hiddenCount)

                    Text("actions")
                        .font(Typo.label)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .transcriptRowFrame()
            }
        }
        .accessibilityLabel("\(hiddenCount) actions")
        .modifier(ExpandableRow(isHovered: isHovered))
        .onHover { isHovered = $0 }
        // Outside the hover treatment, exactly as `TranscriptRowView` puts it outside a row's
        // own: the highlight belongs to the line, not to the gutter the rule is drawn in.
        .padding(.leading, isNested ? TranscriptLayout.nestIndent : 0)
        .overlay(alignment: .leading) {
            if isNested {
                Rectangle()
                    .fill(Palette.border)
                    .frame(width: Metrics.hairline)
                    .padding(.leading, TranscriptLayout.inset)
            }
        }
    }

}
