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
    }

}
