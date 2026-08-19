import SwiftUI

/// Send, or stop what is already running. One control, because the two are never both available
/// and a second button that is disabled most of the time is noise.
///
/// In the create sheet it is the same button doing the same job for a conversation that does not
/// exist yet, so it says what it is about to do and shows the key that does it. See
/// `ComposerIntent`.
struct ComposerSendButton: View {
    var intent: ComposerIntent = .send
    var isRunning: Bool
    var canSend: Bool
    var onSend: @MainActor () -> Void
    var onStop: @MainActor () -> Void

    /// The bordered styles add four points of padding on every edge, so the glyph box has to be
    /// that much smaller than the row for the finished circle to match the controls beside it.
    /// Sizing the glyph at `rowHeight` instead is what made the send button eight points taller
    /// than everything else in the footer.
    private static let glyph = Metrics.rowHeight - Metrics.spacingSmall * 2

    /// A named action rather than a glyph, which only the create sheet uses. A round arrow is
    /// enough for a message going into a conversation the user is looking at; a control that is
    /// about to cut a branch and a worktree should say so, and the return glyph beside it says
    /// which key does it without a tooltip.
    private var isNamed: Bool { intent == .create && !isRunning }

    var body: some View {
        Button(action: activate) {
            if isRunning {
                icon("stop.fill")
            } else if isNamed {
                HStack(spacing: Metrics.spacingSmall) {
                    Text(intent.title)
                    Image(systemName: "return")
                        .imageScale(.small)
                }
                .font(Typo.labelEmphasis)
                .padding(.horizontal, Metrics.spacing)
                .frame(height: Self.glyph)
            } else {
                icon("arrow.up")
            }
        }
        // Prominent to send, quiet to stop. Sending is the action on offer, so it earns the filled
        // accent. Stopping is an escape hatch that sits there for the whole length of a turn, and a
        // saturated red circle pulling the eye for minutes reads as an alarm about work that is
        // going fine. Bordered keeps it obviously a button, and the red says what it does without
        // shouting it.
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(isNamed ? .capsule : .circle)
        // `accentFill`, not `accent`. A prominent button paints a white label on its tint, and
        // white on Bloom teal is 1.6 to 1. Spatie Blue is the ramp member that carries a label.
        .tint(isRunning ? Palette.stop : Palette.accentFill)
        .disabled(!isRunning && !canSend)
        .help(isRunning ? "Stop the agent" : intent.help)
    }

    private func icon(_ systemImage: String) -> some View {
        Label(isRunning ? "Stop the agent" : intent.title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(Typo.labelEmphasis)
            .frame(width: Self.glyph, height: Self.glyph)
    }

    private func activate() {
        if isRunning {
            onStop()
        } else {
            onSend()
        }
    }
}
