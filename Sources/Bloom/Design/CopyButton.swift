import SwiftUI

/// The small button that puts a block of text on the pasteboard.
///
/// One view rather than a fourth hand-rolled copy of it. The behaviour was already agreed by the
/// three that came before (the terminal pane in Settings, a markdown fence, a turn's footer) and
/// this is that behaviour written down: `Clipboard.copy`, the word "Copied" for
/// `Clipboard.flashDuration`, and a tick in place of the sheets while it says so. The wording is
/// the caller's, so a button over a command says "Copy command" exactly as Settings does.
///
/// It was written and then not adopted: the markdown fence and the turn's footer both kept their
/// own copy of it, and the footer's had already lost the tick's tint and the "Copied" a screen
/// reader hears. That is the drift this type exists to stop, so the two of them now call it. The
/// terminal pane in Settings does not, because it is a titled `.bordered` button rather than this
/// one wearing a different style, and pretending otherwise would put a mode in here for one call
/// site.
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
    /// The square the control is drawn and hit in, for a caller that has a row of icon buttons to
    /// line up with. Left alone the button is as big as the glyph in it, which is what a control
    /// revealed by the pointer inside a block of text wants.
    var size: CGFloat?

    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .font(Typo.caption)
                .imageScale(.medium)
                // Clear rather than `.opacity(0)`, for the reason `DiffLineView.commentButton`
                // measured: fading a button or its label to nothing took the element out of the
                // accessibility hierarchy, so the control existed only for a pointer. Nothing
                // gates hit testing here, so this one is reachable by Tab as well.
                .foregroundStyle(isVisible || copied ? (copied ? Palette.positive : Palette.textTertiary) : Color.clear)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
