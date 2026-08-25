import SwiftUI
import AppKit
import BloomCore

/// The composer's editor, as an `NSTextView` rather than `TextField(axis: .vertical)`.
///
/// This was re-evaluated against the native control, and three requirements rule it out. Each one
/// alone is enough; together there is nothing left to build on.
///
/// 1. **The caret offset.** An `@mention` is completed by replacing the range around the insertion
///    point, so the composer has to know where the insertion point is, in UTF-16 units.
///    `TextField` exposes no selection at all, and `TextEditor`'s `TextSelection` binding speaks
///    `String.Index` into an `AttributedString`, where this file's chip layout needs the offset
///    into the storage the chips are drawn in.
/// 2. **Keys before the text system.** Return sends while Shift+Return inserts a newline, and the
///    arrow keys drive whichever completion menu is open while the field keeps first responder.
///    A focused `TextField` swallows Return and both arrows, so `onSubmit` and `onKeyPress` never
///    see the shape of the event, only that something happened.
/// 3. **Measured growth.** The box grows from one line to twelve and only then scrolls, which
///    needs the height the wrapped text actually occupies. `lineLimit(1...12)` grows, but nothing
///    above AppKit reports the used rect, and the twelfth line is where a scroller has to appear.
///
/// Everything else is deliberately kept off the AppKit side: no state lives here that SwiftUI does
/// not own, and the height is reported outwards rather than imposed on the layout, so this cannot
/// start a layout feedback loop the way an intrinsic-size representable can.
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Caret offset in UTF-16 units, so the composer can find the `@token` around it.
    @Binding var caret: Int
    @Binding var isFocused: Bool
    var minLines: Int = 1
    var maxLines: Int = 12
    /// What this field announces itself as.
    ///
    /// A parameter rather than the literal "Message" it was, because two different fields are
    /// this view: the composer, and the review comment field on a diff line. Both said "Message",
    /// so a reader tabbing into a comment was told they were writing a chat turn. The default is
    /// the composer's, which is the caller that has always been right.
    var accessibilityLabel: String = "Message"
    var onHeightChange: @MainActor (CGFloat) -> Void
    var onKey: @MainActor (ComposerKey) -> Bool
    /// Backspace, asked only at a bare caret at the very start of the text, where the thing to the
    /// left of it is not a character. Returns true when the composer took it.
    ///
    /// Its own way in rather than another `ComposerKey`. Everywhere else backspace is a plain
    /// deletion and the text system's own answer, undo included, is the right one, so this is not
    /// a key the callers of the composer have any claim on: it is the editor asking the composer
    /// about the one position where the two disagree about what is there.
    var onBackspaceAtStart: @MainActor () -> Bool = { false }
    /// Files dropped or pasted into the editor, with the stretch of the draft they should take
    /// the place of: where the pointer let go for a drop, the selection for a paste. Returns true
    /// when the composer attached them, which is what keeps AppKit from typing their paths into
    /// the draft instead.
    var onAttach: @MainActor ([AttachmentSource], NSRange) -> Bool
    /// The files the composer knows it has copied for this prompt, so a path that is not one of
    /// Bloom's own copies can still be drawn as a chip. See `AttachmentDraft`.
    var attachmentPaths: [String] = []
    /// A click on a chip, which is a click on the file it names.
    var onOpenAttachment: @MainActor (String) -> Void = { _ in }
    /// The chip the pointer has settled on, which is the card that is up.
    var onHoverAttachment: @MainActor (String?) -> Void = { _ in }
    /// The way in for the one edit the composer makes that the user did not type: a file arriving
    /// after it has been copied. See `ComposerEditorHandle`.
    var handle: ComposerEditorHandle?

    /// The conversation's text size, so what you type is set at the size you read. Without it the
    /// SwiftUI placeholder behind this view would grow and the typed text would not.
    @Environment(\.fontScale) private var fontScale
    /// And the face, so what you type is in the face you read rather than in the one the composer
    /// happens to be built out of.
    @Environment(\.chatFont) private var chatFont

    static var font: NSFont { NSFont.preferredFont(forTextStyle: .body) }

    /// How tall one line of the composer's own face is.
    ///
    /// **Held, because working it out means building a whole TextKit layout manager.** There is no
    /// cheaper way to ask: `NSLayoutManager.defaultLineHeight(for:)` is the only thing that answers
    /// with the number the text system will actually lay a line out at, and the property that
    /// wrapped it allocated one on every read. It is read to size the editor, to clamp the drag, to
    /// place the completion menus and to seed four other views' state, eight to ten times per pass
    /// of the composer's body.
    ///
    /// Keyed on the font itself rather than invalidated by a notification. A body font that has
    /// changed, because the reader changed the system text size, is a different `NSFont` and misses
    /// the cache on its own; a notification would be a second mechanism to keep in step with the
    /// first, and the one that could be forgotten.
    static var lineHeight: CGFloat {
        let font = font
        if let held = heldLineHeight, held.font == font { return held.height }
        let height = NSLayoutManager().defaultLineHeight(for: font)
        heldLineHeight = (font, height)
        return height
    }

    private static var heldLineHeight: (font: NSFont, height: CGFloat)?

    /// How far the writing starts from the sides of the box.
    ///
    /// Five points, which is what `NSTextContainer` gives every native field through
    /// `lineFragmentPadding`, and what a caret sitting hard against a border looks wrong without.
    /// The padding is taken here rather than there so that one number covers the text view and the
    /// SwiftUI placeholder drawn behind it: they are two views showing what reads as one line, and
    /// a point of drift between them makes the hint jump as the first character is typed.
    static let textInset: CGFloat = 5

    /// Rounded to a whole point for the same reason `ScaledFont` rounds, and built from the body
    /// style so an unscaled composer in the system face is byte for byte the font it was before.
    static func font(scale: CGFloat, face: ChatFont) -> NSFont {
        guard scale != 1 || face != .system else { return font }
        return face.nsFont(size: (font.pointSize * scale).rounded())
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Built out of an explicit TextKit 1 stack. A text view made the modern way answers with a
        // TextKit 2 layout, and `usedRect(for:)` is the only measurement that reports the exact
        // height wrapped text occupies.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // Padding is taken as a container inset instead, because `lineFragmentPadding` insets the
        // typed text without insetting the SwiftUI placeholder that sits behind it, and the hint
        // and the first character the user types have to land on the same column.
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = ComposerTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.keyHandler = { [weak coordinator = context.coordinator] event, selection in
            coordinator?.handle(event, selection: selection) ?? false
        }
        // Wrapping depends on the width, so the measurement is only valid until the window is
        // resized. Re-measuring on the frame change is cheaper than laying out speculatively.
        textView.onWidthChange = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.reportHeight(of: textView)
        }
        // Clicking straight into the text makes it first responder without SwiftUI asking, so the
        // flag has to follow AppKit rather than the other way round.
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(to: focused)
        }
        textView.onAttach = { [weak coordinator = context.coordinator] sources, range in
            guard let coordinator else { return false }
            return coordinator.parent.onAttach(sources, coordinator.draftRange(range, in: textView))
        }
        textView.openAttachment = { [weak coordinator = context.coordinator] path in
            coordinator?.parent.onOpenAttachment(path)
        }
        textView.hoverAttachment = { [weak coordinator = context.coordinator] path in
            coordinator?.parent.onHoverAttachment(path)
        }
        // A text view already accepts a file drag, which is exactly the behaviour being replaced:
        // it writes the path into the text. Registering the type explicitly means the drop is
        // offered to `performDragOperation` on every macOS version rather than relying on which
        // types AppKit happens to have registered for a plain text view.
        textView.registerForDraggedTypes(textView.registeredDraggedTypes + [.fileURL])
        textView.font = Self.font(scale: fontScale, face: chatFont)
        textView.textColor = .labelColor
        // The colour macOS uses for a caret, which is not always the accent colour: it stays
        // fixed when the user picks a graphite or multicolour accent.
        textView.insertionPointColor = .textInsertionPointColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        // Writing Tools off, which is the only way to be rid of the orb.
        //
        // AppKit parks a 25 point Siri orb beside the first line of any editable text view it is
        // switched on for. In this layout that lands it outside the box, sitting on the composer's
        // own left border, and it is there from the moment the sheet opens on an empty draft.
        // `.limited` was tried first and keeps it: the orb is the affordance in both of the modes
        // that have one, so there is no setting that keeps the feature and loses the circle.
        //
        // Losing the feature costs this box nothing. What is written here is a prompt to an agent,
        // not prose being drafted, and rewriting or proofreading it is the one editing job nobody
        // has ever wanted done to an instruction.
        textView.writingToolsBehavior = .none
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = CGSize(width: Self.textInset, height: 0)
        textView.autoresizingMask = [.width]
        textView.minSize = CGSize(width: 0, height: 0)
        textView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        context.coordinator.write(text, into: textView, font: textView.font ?? Self.font)
        // Not the literal "Message". This view is the review comment field as well as the
        // composer, and both announced themselves as "Message", so a reader tabbing into a
        // comment on a diff line was told they were writing a chat turn.
        textView.setAccessibilityLabel(accessibilityLabel)

        handle?.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        handle?.textView = textView

        // Ahead of the text, because setting the string re-reads the typing attributes, and
        // because a chip is drawn at the size of the line it sits on.
        let font = Self.font(scale: fontScale, face: chatFont)
        let refaced = textView.font != font
        if refaced {
            textView.font = font
        }

        // Compared as the draft rather than as the string the view is holding: a chip is one
        // character there and a whole path here, and it is the draft the two have to agree about.
        if refaced || ComposerChipText.draft(of: textView.attributedString()) != text {
            context.coordinator.write(text, into: textView, font: font)
            place(caretAt: caret, in: textView, coordinator: context.coordinator)
        } else if caret != context.coordinator.lastReportedCaret {
            // A caret the view did not report is a caret code moved without touching the text:
            // restoring a saved draft puts the insertion point at its end while the string is
            // already in place, so the branch above never runs. Left alone, the view kept
            // {0,0} from its making and its first selection report wrote 0 back over the
            // restored offset.
            place(caretAt: caret, in: textView, coordinator: context.coordinator)
        }

        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        } else if !isFocused, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }

        context.coordinator.reportHeight(of: textView)
    }

    private func place(caretAt caret: Int, in textView: ComposerTextView, coordinator: Coordinator) {
        let location = min(max(caret, 0), (text as NSString).length)
        textView.setSelectedRange(NSRange(
            location: ComposerChipText.storageOffset(
                forDraft: location, in: textView.attributedString()
            ),
            length: 0
        ))
        coordinator.lastReportedCaret = location
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        /// The caret as the view last spoke it, so `updateNSView` can tell a binding echoing the
        /// view back from a programmatic move it still has to apply.
        var lastReportedCaret: Int?
        private var lastReportedHeight: CGFloat = 0

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerTextView else { return }
            // Typing next to a chip must not inherit the chip: an attachment carried in the
            // typing attributes would draw the next character as a second copy of the same file.
            textView.typingAttributes = [
                .font: textView.font ?? ComposerTextEditor.font,
                .foregroundColor: NSColor.labelColor,
            ]
            parent.text = ComposerChipText.draft(of: textView.attributedString())
            let caret = draftOffset(textView.selectedRange().location, in: textView)
            parent.caret = caret
            lastReportedCaret = caret
            reportHeight(of: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? ComposerTextView else { return }
            let location = draftOffset(textView.selectedRange().location, in: textView)
            lastReportedCaret = location
            if parent.caret != location { parent.caret = location }
        }

        /// Puts a draft into the view: words as words, files as the chips that stand for them.
        func write(_ text: String, into textView: ComposerTextView, font: NSFont) {
            let storage = ComposerChipText.storage(
                for: text, paths: parent.attachmentPaths, font: font, color: .labelColor
            )
            textView.textStorage?.setAttributedString(storage)
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        }

        /// A position in the view, in the units the composer counts the draft in.
        func draftOffset(_ offset: Int, in textView: ComposerTextView) -> Int {
            ComposerChipText.draftOffset(forStorage: offset, in: textView.attributedString())
        }

        /// The stretch of the draft a drop or a paste is aimed at.
        func draftRange(_ range: NSRange, in textView: ComposerTextView) -> NSRange {
            let storage = textView.attributedString()
            let start = ComposerChipText.draftOffset(forStorage: range.location, in: storage)
            let end = ComposerChipText.draftOffset(
                forStorage: range.location + range.length, in: storage
            )
            return NSRange(location: start, length: max(end - start, 0))
        }

        /// Deferred by one turn of the main actor: the responder change can land in the middle of a
        /// SwiftUI update, and writing state there is how a view ends up fighting itself.
        func focusChanged(to focused: Bool) {
            guard parent.isFocused != focused else { return }
            Task { [weak self] in
                guard let self, self.parent.isFocused != focused else { return }
                self.parent.isFocused = focused
            }
        }

        /// Maps a raw key event to composer intent. Shift+Return is deliberately not mapped: it
        /// falls through to AppKit, which inserts the newline for us.
        func handle(_ event: NSEvent, selection: NSRange) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 36, 76: // Return, Enter
                if flags.contains(.shift) { return false }
                return parent.onKey(flags.contains(.command) ? .commandReturn : .returnKey)
            case 53: // Escape
                return parent.onKey(.escape)
            case 125: // Down
                return parent.onKey(.down)
            case 126: // Up
                return parent.onKey(.up)
            case 48: // Tab
                return parent.onKey(.tab)
            case 51: // Delete
                // Only the bare press, and only with nothing selected and nothing to the left of
                // the caret. A modified delete, a selection, or a caret anywhere else is the text
                // system's own business, and taking those would cost the editor its undo.
                guard flags.isEmpty, selection.length == 0, selection.location == 0 else {
                    return false
                }
                return parent.onBackspaceAtStart()
            default:
                return false
            }
        }

        /// Measures what the text actually occupies and clamps it to the growth window. Reported
        /// asynchronously because this runs inside a SwiftUI update and must not write state back
        /// into the same pass.
        func reportHeight(of textView: ComposerTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            // Before the first layout pass the view has no width, and text wrapped to nothing
            // measures as one line per word. Measuring then would open the box at full height.
            guard textView.bounds.width > 1 else { return }

            layout.ensureLayout(for: container)

            let line = layout.defaultLineHeight(for: textView.font ?? ComposerTextEditor.font)
            let used = layout.usedRect(for: container).height
            let minimum = CGFloat(parent.minLines) * line
            let maximum = CGFloat(parent.maxLines) * line
            let height = min(max(used, minimum), maximum).rounded(.up)

            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            let report = parent.onHeightChange
            Task { report(height) }
        }
    }
}

/// The one edit the composer makes that nobody typed: a file arriving in the text after it has
/// been copied into the worktree.
///
/// It goes through the text view rather than through the binding, and that is the whole reason
/// this exists. An edit made here is an edit the text system knows about, so Command+Z takes the
/// file back out and Command+Shift+Z puts it back, in order with the words typed either side of
/// it, without anything having to remember what a draft looked like a moment ago. Replacing the
/// string from the SwiftUI side would leave the text right and the undo stack describing a
/// document that no longer exists.
///
/// Held by the view that owns the draft and handed down, so nothing here outlives the box it
/// belongs to: the reference is weak, and a file that finishes copying after the composer has gone
/// falls back to the plain write, which is still the correct draft.
@MainActor
final class ComposerEditorHandle {
    fileprivate weak var textView: ComposerTextView?

    /// Writes files into the draft at `range`, measured in the draft's own units.
    ///
    /// Returns false when there is no editor to write into, or when the one there is holding a
    /// different draft from the one the caller measured `range` against. Both are the caller's
    /// signal to write the draft itself instead, which is the same edit made without the text
    /// system's undo: copying a file takes long enough that the composer can have been handed a
    /// new draft in the meantime, and an offset into a sentence that is no longer there would put
    /// the file in the wrong place or take a word away with it.
    @discardableResult
    func insert(_ paths: [String], replacing range: NSRange, into draft: String) -> Bool {
        guard !paths.isEmpty, let textView, let storage = textView.textStorage else { return false }

        let held = textView.attributedString()
        guard ComposerChipText.draft(of: held) == draft else { return false }
        let string = held.string as NSString
        let start = min(
            ComposerChipText.storageOffset(forDraft: range.location, in: held), string.length
        )
        let end = min(
            ComposerChipText.storageOffset(
                forDraft: range.location + range.length, in: held
            ),
            string.length
        )
        let replaced = NSRange(location: start, length: max(end - start, 0))

        let before = start > 0 ? string.substring(with: NSRange(location: start - 1, length: 1)) : ""
        let after = replaced.upperBound < string.length
            ? string.substring(with: NSRange(location: replaced.upperBound, length: 1))
            : ""
        // The same answer `AttachmentDraft` gives when it writes a path into a draft, asked of the
        // same two characters. A chip is not a space, so a file dropped against another one is
        // spaced off it exactly as it would be against a word.
        let (lead, trail) = AttachmentDraft.padding(before: before, after: after)

        let font = textView.font ?? ComposerTextEditor.font
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let written = NSMutableAttributedString(string: lead, attributes: plain)
        for (index, path) in paths.enumerated() {
            if index > 0 {
                written.append(NSAttributedString(string: " ", attributes: plain))
            }
            written.append(ComposerChipText.chip(for: path, font: font))
        }
        written.append(NSAttributedString(string: trail, attributes: plain))

        // What makes it undoable, and the string matters: `nil` means "only the attributes are
        // changing", which registers an undo that puts the attributes back and leaves the file in
        // the sentence. The characters actually going in are what has to be named, which for a
        // chip is the one character it is made of.
        // A file arriving is not part of whatever word was being typed a moment ago, so the typing
        // group is closed on both sides of it: one press of Command+Z takes the file back out and
        // leaves the sentence, and the next one takes back the word.
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: replaced, replacementString: written.string) else {
            return false
        }
        storage.beginEditing()
        storage.replaceCharacters(in: replaced, with: written)
        storage.endEditing()
        textView.didChangeText()
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName(paths.count == 1 ? "Attach" : "Attach \(paths.count) Files")
        textView.setSelectedRange(NSRange(location: replaced.location + written.length, length: 0))
        return true
    }
}
