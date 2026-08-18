import SwiftUI

/// Send, or stop what is already running. One control, because the two are never both available
/// and a second button that is disabled most of the time is noise.
struct ComposerSendButton: View {
    var isRunning: Bool
    var canSend: Bool
    var onSend: @MainActor () -> Void
    var onStop: @MainActor () -> Void

    var body: some View {
        Button(action: activate) {
            Label(
                isRunning ? "Stop the agent" : "Send",
                systemImage: isRunning ? "stop.fill" : "arrow.up"
            )
            .labelStyle(.iconOnly)
            .font(Typo.captionEmphasis)
            .frame(width: Metrics.rowHeight, height: Metrics.rowHeight)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(isRunning ? Palette.negative : Palette.accent)
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
