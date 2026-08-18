import SwiftUI

/// Send, or stop what is already running. One control, because the two are never both available
/// and a second button that is disabled most of the time is noise.
struct ComposerSendButton: View {
    var isRunning: Bool
    var canSend: Bool
    var onSend: @MainActor () -> Void
    var onStop: @MainActor () -> Void

    /// The bordered styles add four points of padding on every edge, so the glyph box has to be
    /// that much smaller than the row for the finished circle to match the controls beside it.
    /// Sizing the glyph at `rowHeight` instead is what made the send button eight points taller
    /// than everything else in the footer.
    private static let glyph = Metrics.rowHeight - Metrics.spacingSmall * 2

    var body: some View {
        Button(action: activate) {
            Label(
                isRunning ? "Stop the agent" : "Send",
                systemImage: isRunning ? "stop.fill" : "arrow.up"
            )
            .labelStyle(.iconOnly)
            .font(Typo.labelEmphasis)
            .frame(width: Self.glyph, height: Self.glyph)
        }
        // Prominent to send, quiet to stop. Sending is the action on offer, so it earns the filled
        // accent. Stopping is an escape hatch that sits there for the whole length of a turn, and a
        // saturated red circle pulling the eye for minutes reads as an alarm about work that is
        // going fine. Bordered keeps it obviously a button, and the red says what it does without
        // shouting it.
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(isRunning ? Palette.stop : Palette.accent)
        .disabled(!isRunning && !canSend)
        .help(isRunning ? "Stop the agent" : "Send (Return)")
    }

    private func activate() {
        if isRunning {
            onStop()
        } else {
            onSend()
        }
    }
}
