import AppKit

/// An `NSTextView` that offers each key press to the composer before typing it, says when it was
/// resized or focused so the SwiftUI side can keep up, and hands over anything that arrives as a
/// file rather than as text.
final class ComposerTextView: NSTextView {
    /// Offered every key press, together with what is selected when it arrives: the composer's
    /// answer to backspace depends on whether the caret is a bare insertion point at the start,
    /// and only the text view knows that.
    var keyHandler: (@MainActor (NSEvent, NSRange) -> Bool)?
    var onWidthChange: (@MainActor () -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?
    /// Offered every file dropped or pasted into the editor. Returns true when the composer took
    /// it, which is what stops AppKit from doing what it does by default: typing the file's path
    /// into the draft as a sentence about the file, instead of attaching the file.
    var onAttach: (@MainActor ([AttachmentSource]) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event, selectedRange()) == true { return }
        super.keyDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onWidthChange?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    /// Without this the window's default button, or the field editor's own cancel handling, can
    /// swallow Escape before `keyDown` ever sees it.
    override func cancelOperation(_ sender: Any?) {
        // Handled in keyDown. Overridden so AppKit does not beep.
    }

    // MARK: - Files in

    /// A drag of files becomes attachments. Everything else, a drag of text most of all, is left
    /// to the text system, which has always handled it well.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = Self.files(on: sender.draggingPasteboard)
        if !files.isEmpty, onAttach?(files) == true { return true }
        return super.performDragOperation(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.files(on: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.files(on: sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    /// Command+V. A screenshot is the single most common thing anybody attaches, and it arrives on
    /// the clipboard as bytes with no file behind it at all, so this is the one door where an
    /// attachment has to be written from nothing.
    override func paste(_ sender: Any?) {
        let sources = Self.attachables(on: .general)
        if !sources.isEmpty, onAttach?(sources) == true { return }
        super.paste(sender)
    }

    /// Paste and Match Style lands here rather than in `paste`. The editor is plain text, so the
    /// two mean exactly the same thing.
    override func pasteAsPlainText(_ sender: Any?) {
        let sources = Self.attachables(on: .general)
        if !sources.isEmpty, onAttach?(sources) == true { return }
        super.pasteAsPlainText(sender)
    }

    // MARK: - Reading a pasteboard

    static func files(on pasteboard: NSPasteboard) -> [AttachmentSource] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return (urls ?? []).map { .file($0) }
    }

    /// What is worth attaching from a clipboard, which is not the same question as what is worth
    /// attaching from a drag.
    ///
    /// Files win outright. Failing that, image data counts only when the clipboard carries no text
    /// beside it: copying a paragraph out of a web page brings the pictures along with the words,
    /// and turning that into an attachment would throw away what the user actually copied.
    static func attachables(on pasteboard: NSPasteboard) -> [AttachmentSource] {
        let files = files(on: pasteboard)
        if !files.isEmpty { return files }

        let text = pasteboard.string(forType: .string) ?? ""
        guard text.isEmpty else { return [] }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            let ext = type == .png ? "png" : "tiff"
            return [.data(data, filename: PromptAttachments.pastedFilename(extension: ext))]
        }
        return []
    }
}
