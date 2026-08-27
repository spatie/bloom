import BloomCore
import SwiftUI

/// The one line that stands for a turn's working.
///
/// Collapsed, the count replaces the newest row's glyph and the rest of that row stays intact.
/// This keeps the current action visible while making the whole block one compact control.
/// Expanded, the ordinary disclosure label returns so there is an unambiguous way to close it.
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
                    latest
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .overlay(alignment: .leading) { countBadge }
                } else {
                    HStack(spacing: TranscriptLayout.glyphGap) {
                        TranscriptDisclosure(isExpanded: isExpanded, isVisible: true)
                            .frame(width: TranscriptLayout.glyphWidth)

                        Text(TranscriptFold.label(hiding: hiddenCount, showsMore: showsMore))
                            .font(Typo.label)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)
                    }
                    .transcriptRowFrame()
                }
            }
        }
        .accessibilityLabel("\(hiddenCount) steps, latest activity")
        .modifier(ExpandableRow(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }

    private var countBadge: some View {
        Text(hiddenCount, format: .number)
            .font(Typo.micro)
            .fontWeight(.semibold)
            .foregroundStyle(Color.white)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: 19, height: 19)
            .background(Palette.textTertiary, in: Circle())
            .frame(width: TranscriptLayout.glyphWidth)
    }
}
