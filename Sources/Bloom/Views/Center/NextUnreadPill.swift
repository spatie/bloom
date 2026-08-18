import SwiftUI

/// The floating "you are behind" affordance.
///
/// It lives on its own because it is anchored to the composer but the transcript renders one too
/// when the user scrolls far up.
struct NextUnreadPill: View {
    var count: Int
    var action: @MainActor () -> Void

    var body: some View {
        // A real prominent button rather than a hand-painted capsule: it then gets the pressed
        // and disabled states, the hover response and the accent tint from the system instead of
        // from an opacity that only changed on hover.
        Button(action: action) {
            Label(
                count == 1 ? "Next unread" : "Next unread (\(count))",
                systemImage: "arrow.down"
            )
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        // `accentFill` for the reason spelled out on `ComposerSendButton`: this is a filled
        // control with a white label on it.
        .tint(Palette.accentFill)
        // Black rather than the label colour, which would be a white glow in dark mode.
        .shadow(color: .black.opacity(0.2), radius: Metrics.spacingSmall, y: Metrics.spacingTight)
        .help("Jump to the next unread reply")
    }
}
