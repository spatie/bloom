import SwiftUI

/// The floating "you are behind" affordance.
///
/// It lives on its own because it is anchored to the composer but the transcript renders one too
/// when the user scrolls far up.
struct NextUnreadPill: View {
    var count: Int
    var action: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(count == 1 ? "Next unread" : "Next unread (\(count))")
                    .font(Typo.captionEmphasis)
            } icon: {
                Image(systemName: "arrow.down")
                    .font(Typo.micro)
            }
            .foregroundStyle(Palette.textInverted)
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.rowHeight)
            .background(Palette.accent.opacity(isHovered ? 1 : 0.9), in: .capsule)
            .shadow(
                color: Palette.textPrimary.opacity(0.2),
                radius: Metrics.corner,
                y: Metrics.hairline * 2
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
