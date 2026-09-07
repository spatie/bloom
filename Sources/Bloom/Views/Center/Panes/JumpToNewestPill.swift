import SwiftUI

/// The route back to the live end, sharing the pinned message shortcut's glass and chevron.
struct JumpToNewestPill: View {
    var action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingWide) {
                Text("Jump to newest")
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.textPrimary)

                Image(systemName: "chevron.down")
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Palette.textSecondary.opacity(0.08), in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.barHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .pointerStyle(.link)
        .help("Jump to the newest row")
    }
}
