import BloomCore
import SwiftUI

/// The one line that stands for a turn's working.
///
/// The disclosure and count keep the same geometry in both states. Collapsed, the rest of the
/// newest row stays intact. Expanded, a quiet noun replaces it while the disclosed rows provide
/// the detail. Only the caret and the content after the badge change when the row is toggled.
struct TranscriptFoldRowView: View {
    var hiddenCount: Int
    var showsMore: Bool
    var isExpanded: Bool
    var latest: AnyView?
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        ExpandableRowHeader(isExpanded: isExpanded, onToggle: onToggle) {
            Group {
                if !isExpanded, let latest {
                    HStack(spacing: Metrics.spacingSmall) {
                        TranscriptDisclosure(isExpanded: false, isVisible: true)
                            .frame(width: TranscriptLayout.disclosureWidth)

                        latest
                            .environment(\.transcriptFoldCount, hiddenCount)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                } else {
                    HStack(spacing: Metrics.spacingSmall) {
                        TranscriptDisclosure(isExpanded: isExpanded, isVisible: true)
                            .frame(width: TranscriptLayout.disclosureWidth)

                        HStack(spacing: TranscriptLayout.glyphGap) {
                            TranscriptGlyph(symbol: "circle")
                                .environment(\.transcriptFoldCount, hiddenCount)

                            Text(showsMore ? "earlier steps" : "steps")
                                .font(Typo.label)
                                .foregroundStyle(Palette.textTertiary)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .transcriptRowFrame()

                    }
                }
            }
        }
        .accessibilityLabel("\(hiddenCount) steps, latest activity")
        .modifier(ExpandableRow(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }

}
