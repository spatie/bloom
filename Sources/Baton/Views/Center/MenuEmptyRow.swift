import SwiftUI

/// What a completion menu says when it has nothing to offer. A single quiet line: the menu is
/// already an overlay on top of what the user is typing, so a full empty state would shout.
struct MenuEmptyRow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Typo.body)
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
            // The same two insets a populated menu applies, one from the panel and one from the
            // row, so the message starts exactly where a file name would.
            .padding(.horizontal, Metrics.spacing)
            .frame(height: Metrics.rowHeight)
            .padding(Metrics.spacingSmall)
    }
}
