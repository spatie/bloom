import SwiftUI
import BloomCore

/// The time of a message, drawn beside it while the pointer is on it.
///
/// Meant for an `overlay`: it must never take layout space, because a row's height is cached and
/// a label that widened a bubble on hover would rewrap its text.
struct MessageTimeLabel: View {
    var date: Date

    /// The height of the copy button this label sits beside, so the two centre on one line.
    static let height: CGFloat = 18

    var body: some View {
        Text(MessageTimestamp.label(for: date))
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
            .fixedSize()
            .frame(height: Self.height)
            // Backed with the ground so that, in a pane too narrow to leave it room, it covers the
            // end of the line under it instead of printing over it.
            .padding(.horizontal, Metrics.spacingTight)
            .background(Palette.surface, in: Capsule())
            .allowsHitTesting(false)
    }
}
