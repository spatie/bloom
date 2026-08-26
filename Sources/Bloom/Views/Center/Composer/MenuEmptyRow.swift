import SwiftUI

/// What a completion menu says when it has nothing to offer. A single quiet line: the menu is
/// already an overlay on top of what the user is typing, so a full empty state would shout.
struct MenuEmptyRow: View {
    var text: String
    /// Where the sentence starts, measured from the panel's edge.
    ///
    /// Passed in rather than assumed, because it is the MENU's number and not this row's. The
    /// default is the two insets every completion panel applies, one from the panel and one from
    /// the row, so the message starts exactly where a file name would. `QuickPromptMenu` holds its
    /// list further off the edge than the others and hands its own in: written here, its two
    /// empty states indented to 10 and its third to 14, which is the "one column rather than three
    /// that nearly agree" its own doc asks for.
    var inset: CGFloat = Metrics.spacing + Metrics.spacingSmall

    var body: some View {
        Text(text)
            .font(Typo.body)
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
            .frame(height: Metrics.rowHeight)
            .padding(.horizontal, inset)
            .padding(.vertical, Metrics.spacingSmall)
    }
}
