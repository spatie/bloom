import SwiftUI

/// The small button that puts a block of text on the pasteboard.
///
/// One view rather than a fourth hand-rolled copy of it. The behaviour was already agreed by the
/// three that came before (the terminal pane in Settings, a markdown fence, a turn's footer) and
/// this is that behaviour written down: `Clipboard.copy`, the word "Copied" for
/// `Clipboard.flashDuration`, and a tick in place of the sheets while it says so. The wording is
/// the caller's, so a button over a command says "Copy command" exactly as Settings does.
///
/// The flash task is cancelled and restarted rather than left to run, so a second copy inside the
/// window does not have the first one's timer clear the label out from under it a moment later.
///
/// `isVisible` fades rather than removes. A control that appears on hover must not be able to move
/// what is under it: at opacity zero it still holds its place in the layout, so the text beside it
/// keeps the width it had before the pointer arrived. Same reasoning as `TranscriptDisclosure`.
struct CopyButton: View {
    /// What lands on the pasteboard. The whole of it: a row shows a command cut to the width it
    /// had, and the cut version is the one thing nobody wants pasted into a terminal.
    var text: String
    /// What the button is for, in the caller's words. Shown as the tooltip and to VoiceOver.
    var title: String = "Copy"
    var isVisible: Bool = true

    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .font(Typo.caption)
                .imageScale(.medium)
                .foregroundStyle(copied ? Palette.positive : Palette.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isVisible || copied ? 1 : 0)
        // Still says "Copied" while it is showing the tick, because the tick alone is not an
        // answer to somebody who cannot see it.
        .help(copied ? "Copied" : title)
        .accessibilityLabel(copied ? "Copied" : title)
        .onDisappear { reset?.cancel() }
    }

    private func copy() {
        Clipboard.copy(text)
        copied = true
        reset?.cancel()
        reset = Task {
            try? await Task.sleep(for: Clipboard.flashDuration)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
