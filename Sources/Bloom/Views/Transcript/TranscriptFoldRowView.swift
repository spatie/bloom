import SwiftUI
import BloomCore

/// The one line that stands for a turn's working: a triangle and the words for what is behind it.
///
/// While the turn is running it stands above the row happening now, and the count climbs as the
/// agent works. Once the answer has landed the whole of the working is behind it and it sits
/// between the reader's own message and the answer, which is where the owner asked for it.
///
/// **Words rather than a number in a grey oval**, which is what was asked for and which macOS has
/// already spent on notification badges. `TranscriptFold.label` carries that argument and the
/// prior art it was settled from; what belongs here is that the line is drawn on the columns every
/// other row uses, so a folded run reads as one of the rows rather than as a control that has
/// landed among them.
///
/// **Its chevron is always drawn, and it is the only one in this pane that is.** Everywhere else
/// the chevron appears under the pointer, because the row beside it already says what it is and a
/// column of triangles down a dense transcript is noise. This row says nothing except that there
/// is more here, so hiding its only affordance until the pointer arrives would leave a line
/// nobody could tell was clickable.
struct TranscriptFoldRowView: View {
    var hiddenCount: Int
    /// Whether any of the turn's working is still drawn below this line, which is what decides
    /// whether the count is of the rows "earlier" than something or of the whole of it. See
    /// `TranscriptFold.label`.
    var showsMore: Bool
    var isExpanded: Bool
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        ExpandableRowHeader(isExpanded: isExpanded, onToggle: onToggle) {
            HStack(spacing: TranscriptLayout.glyphGap) {
                // In the glyph column's width rather than its own, so the words start exactly
                // where a tool row's label starts. A chevron framed at `disclosureWidth` here
                // would put this line two points to the left of every row it stands for.
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
        .modifier(ExpandableRow(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }
}
