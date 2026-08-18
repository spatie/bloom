import SwiftUI

/// What a completion menu says when it has nothing to offer. A single quiet line: the menu is
/// already an overlay on top of what the user is typing, so a full empty state would shout.
struct MenuEmptyRow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Typo.label)
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.rowHeight)
    }
}
