import SwiftUI

/// The text box a review comment is written in, whether it is being written for the first time or
/// rewritten in place.
///
/// It is the composer's own editor, not a second one. `ComposerEditor` already answers every
/// question this box has to answer, and answers them the way the box at the bottom of the
/// transcript does: Return submits, Shift+Return inserts a line break (`ComposerTextEditor`
/// deliberately lets a shifted Return fall through to AppKit, which is what makes the break the
/// text system's own edit and therefore undoable), Escape cancels, and the box grows to fit what
/// has been typed and only then scrolls. Writing that a second time here with `TextField(axis:)`
/// is how two implementations of Shift+Return in one app start disagreeing, and the native
/// control cannot do it anyway: a focused `TextField` swallows Return before anything above
/// AppKit can see whether Shift was down.
///
/// One rule, both places, is also why this is a type rather than two call sites: the editor the
/// gutter `+` opens and the editor the pencil opens are the same box with different words on the
/// button.
struct ReviewCommentField: View {
    @Binding var text: String
    var placeholder: String
    /// Return, and the confirm button.
    var onSubmit: @MainActor () -> Void
    /// Escape, and the cancel button.
    var onCancel: @MainActor () -> Void

    /// The composer's editor reports the caret so an `@mention` can be completed around it.
    /// Nothing here completes anything, so it is read and dropped.
    @State private var caret = 0
    @State private var isFocused = false
    @State private var contentHeight = ComposerTextEditor.lineHeight

    /// One line at rest, because most notes on a line of code are one sentence and a box that
    /// opens three lines tall pushes the diff around for nothing.
    private static let minimumLines: CGFloat = 1
    /// Where it stops growing and starts scrolling. Eight is what the box could show before this
    /// grew at all (`lineLimit(1...8)`), kept so a long note reads the same as it did, and it is
    /// as far as a band can grow inside a diff without the code it is about leaving the screen.
    private static let maximumLines: CGFloat = 8

    var body: some View {
        ComposerEditor(
            text: $text,
            caret: $caret,
            isFocused: $isFocused,
            height: height,
            onContentHeightChange: { contentHeight = $0 },
            onKey: handle(key:),
            // A file dropped on a review comment is not an attachment: the comment goes into the
            // prompt as text, so the path is the most useful thing it could become, and false is
            // what leaves AppKit to type it.
            onAttach: { _, _ in false },
            placeholder: placeholder
        )
        .composerBox(isFocused: $isFocused)
        // The editor is opened by pressing something, so the caret belongs in it without a second
        // click. `ComposerTextEditor` reports focus back the moment AppKit gives it, so this is a
        // request rather than a claim.
        .onAppear { isFocused = true }
    }

    private var height: CGFloat {
        let line = ComposerTextEditor.lineHeight
        return min(max(contentHeight, line * Self.minimumLines), line * Self.maximumLines)
    }

    /// - Returns: true when this box took the key, which is what stops the text system from also
    ///   acting on it.
    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .returnKey, .commandReturn:
            // Command+Return sends in the composer, so it confirms here. Somebody who has learned
            // one of the two boxes should not find the other refusing the same hand.
            onSubmit()
            return true
        case .escape:
            onCancel()
            return true
        case .up, .down, .tab:
            // No menu opens over this box, so the text system's own answers are the right ones.
            return false
        }
    }
}
