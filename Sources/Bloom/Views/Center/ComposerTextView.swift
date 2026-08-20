import AppKit
import BloomCore

/// An `NSTextView` that offers each key press to the composer before typing it, says when it was
/// resized or focused so the SwiftUI side can keep up, and hands over anything that arrives as a
/// file or a picture rather than as text.
final class ComposerTextView: NSTextView {
    /// Offered every key press, together with what is selected when it arrives: the composer's
    /// answer to backspace depends on whether the caret is a bare insertion point at the start,
    /// and only the text view knows that.
    var keyHandler: (@MainActor (NSEvent, NSRange) -> Bool)?
    var onWidthChange: (@MainActor () -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?
    /// Offered everything dropped or pasted into the editor that is not text. Returns true when
    /// the composer took it, which is what stops AppKit from doing what it does by default: typing
    /// the file's path into the draft as a sentence about the file, instead of attaching the file.
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

    /// A drag becomes attachments, on the same terms as a paste: files if there are files, a
    /// picture if that is all there is, and otherwise nothing, so a drag of text is still a drag
    /// of text and the text system handles it as well as it always has.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let sources = Self.attachables(on: sender.draggingPasteboard)
        if !sources.isEmpty, onAttach?(sources) == true { return true }
        return super.performDragOperation(sender)
    }

    // Both of these are asked again and again while the pointer moves, so they ask whether there
    // is anything to take rather than taking it: reading the bytes here would copy a screenshot
    // out of the drag on every frame of it.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.hasAttachables(on: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.hasAttachables(on: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
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

    /// Why pasting a screenshot did nothing at all until now.
    ///
    /// Command+V is not a key this view is offered. It is the key equivalent of the Edit menu's
    /// Paste item, and a menu item that validates as disabled is never dispatched: the override
    /// above was there, correct, and unreachable. AppKit validates Paste by asking the first
    /// responder whether the clipboard holds any type it can read, and a plain text view's list is
    /// strings, RTF, HTML, URLs and colours. A screenshot copied rather than saved puts `public.png`
    /// and `public.tiff` on the board and nothing else, so the intersection is empty, the item is
    /// grey, and the key press is swallowed with no beep and no clue.
    ///
    /// So the answer is not to claim those types as readable, which would invite the text system to
    /// insert a picture into a plain text view, but to say that this particular view has something
    /// to do with the board even when the text system does not. Everything else, Paste included
    /// when the board does carry text, is left to `super`.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
            if super.validateUserInterfaceItem(item) { return true }
            // Whether there is something, never the something itself. Validation runs every time
            // the Edit menu opens, and reading a fifty megabyte picture off the clipboard to
            // decide whether a menu item is grey would be paid for by whoever opened the menu.
            return Self.hasAttachables(on: .general)
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Reading a pasteboard

    /// What is worth attaching from a pasteboard, and what is better left to the text system.
    ///
    /// The rules are `PastedAttachment.plan`, in BloomCore, where they can be asserted on. This is
    /// the part that cannot be: turning an `NSPasteboard` into the two facts that decide, and then
    /// reading the bytes the decision asked for.
    ///
    /// Reading the bytes is the expensive half, so it is deliberately the last thing that happens
    /// and the only caller that pays for it is a paste or a drop that has already landed.
    static func attachables(on pasteboard: NSPasteboard) -> [AttachmentSource] {
        let items = pasteboard.pasteboardItems ?? []
        switch plan(for: items, on: pasteboard) {
        case .text:
            return []
        case .files(let paths):
            return paths.map { .file(URL(filePath: $0)) }
        case .images(let images):
            var taken: Set<String> = []
            return images.compactMap { image in
                guard items.indices.contains(image.item),
                      let data = items[image.item].data(
                          forType: NSPasteboard.PasteboardType(image.format.uti)
                      ),
                      !data.isEmpty
                else { return nil }
                // The name it earns is the format it will be written as, which is not always the
                // format it was read as: a TIFF becomes a PNG on the way in.
                let name = PastedAttachment.filename(
                    format: image.format.written, avoiding: taken
                )
                taken.insert(name)
                return .image(data, format: image.format, named: name)
            }
        }
    }

    /// Whether this pasteboard holds anything the composer would take, decided without reading a
    /// single byte of it.
    static func hasAttachables(on pasteboard: NSPasteboard) -> Bool {
        plan(for: pasteboard.pasteboardItems ?? [], on: pasteboard) != .text
    }

    private static func plan(
        for items: [NSPasteboardItem], on pasteboard: NSPasteboard
    ) -> PastedAttachment.Plan {
        let offers = items.map { item in
            PastedAttachment.Offer(
                filePath: item.fileURL()?.path,
                types: item.types.map(\.rawValue)
            )
        }
        // Whether there is text, never the text itself. A clipboard is the user's own business and
        // nothing here has any reason to read what is on it.
        let hasText = (pasteboard.string(forType: .string)?.isEmpty == false)
        return PastedAttachment.plan(items: offers, hasText: hasText)
    }
}

private extension NSPasteboardItem {
    /// The file this item points at, if it points at one.
    ///
    /// A file URL is read off the item rather than off the whole board, because a board is a list
    /// of items and reading it whole loses which picture belonged to which file. Anything that is
    /// not a file, an `https` link most of all, is not a file: pasting a URL types the URL, which
    /// is what it has always done.
    func fileURL() -> URL? {
        guard let string = string(forType: .fileURL),
              let url = URL(string: string), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }
}
