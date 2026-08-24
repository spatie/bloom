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
    /// Offered everything dropped or pasted into the editor that is not text, together with the
    /// stretch of text it should take the place of. Returns true when the composer took it, which
    /// is what stops AppKit from doing what it does by default: typing the file's path into the
    /// draft as a sentence about the file, instead of attaching the file.
    ///
    /// The range is the whole of "where does this go". A drop carries the character the pointer
    /// was over, so the file lands on the word it was dropped on rather than wherever the caret
    /// happened to be left; a paste carries the selection, so it replaces what was selected
    /// exactly as pasting anything else does.
    var onAttach: (@MainActor ([AttachmentSource], NSRange) -> Bool)?
    /// A click on a chip, which is a click on the file it names.
    var openAttachment: (@MainActor (String) -> Void)?
    /// The chip the pointer has settled on, or nil when it has left one. What raises the card that
    /// draws the file above the box.
    var hoverAttachment: (@MainActor (String?) -> Void)?

    /// Where the pointer is now, and the wait before it counts as settled.
    fileprivate var hoveredPath: String?
    fileprivate var hoverTask: Task<Void, Never>?
    fileprivate var hoverArea: NSTrackingArea?

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
        if !sources.isEmpty, onAttach?(sources, dropRange(for: sender)) == true { return true }
        return super.performDragOperation(sender)
    }

    /// Where a drop landed, as a place in the text.
    ///
    /// A file goes where it was dropped, which is the whole point of dropping it on a word rather
    /// than on the box: `characterIndexForInsertion` is the same answer AppKit gives itself when
    /// it decides where dragged text would go, so a file and a sentence land in the same place for
    /// the same gesture. Length zero, because a drop displaces nothing.
    private func dropRange(for sender: any NSDraggingInfo) -> NSRange {
        let point = convert(sender.draggingLocation, from: nil)
        return NSRange(location: characterIndexForInsertion(at: point), length: 0)
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
        // At the caret, over the selection if there is one, which is what pasting means
        // everywhere else in the system.
        if !sources.isEmpty, onAttach?(sources, selectedRange()) == true { return }
        super.paste(sender)
    }

    /// Paste and Match Style lands here rather than in `paste`. The editor is plain text, so the
    /// two mean exactly the same thing.
    override func pasteAsPlainText(_ sender: Any?) {
        let sources = Self.attachables(on: .general)
        if !sources.isEmpty, onAttach?(sources, selectedRange()) == true { return }
        super.pasteAsPlainText(sender)
    }

    // MARK: - Files out

    /// Copying a selection that contains a chip puts the path on the clipboard.
    ///
    /// Without this it would put `NSTextAttachment`'s object replacement character there, which is
    /// an invisible box in every other app. What the reader selected reads as a path in the box,
    /// so a path is what they get: the same text the agent is going to be handed.
    override func writeSelection(
        to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard type == .string, let storage = textStorage else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        let text = selectedRanges
            .map { ComposerChipText.draft(of: storage, in: $0.rangeValue) }
            .joined(separator: "\n")
        pasteboard.setString(text, forType: .string)
        return true
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


// MARK: - The pointer on a chip

extension ComposerTextView {
    /// How long the pointer has to rest before the card opens. The same delay the chips above the
    /// box used, for the same reason: crossing the line on the way to the send button should show
    /// nothing.
    private static var hoverDelay: Duration { .milliseconds(350) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        guard hoverAttachment != nil else { return }
        // `.inVisibleRect` keeps it right through every resize of a box that grows with its text,
        // and `.mouseMoved` is what makes the moves arrive at all without the window being asked
        // to deliver them to everybody.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(over: attachmentPath(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(over: nil)
    }

    /// The file under a point, or nil for anywhere that is not a chip.
    ///
    /// The glyph's own rectangle is checked rather than the insertion point the same coordinates
    /// would give: an insertion index is the nearest gap between characters and exists everywhere
    /// in the box, including the empty space to the right of the last word, which would raise a
    /// card for a file the pointer is nowhere near.
    private func attachmentPath(at point: CGPoint) -> String? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)

        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(
            for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction
        )
        guard layout.numberOfGlyphs > glyph else { return nil }

        let rect = layout.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: container
        )
        guard rect.contains(inContainer) else { return nil }

        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < (string as NSString).length else { return nil }
        return textStorage?.attribute(
            ComposerChipText.pathKey, at: index, effectiveRange: nil
        ) as? String
    }

    private func hover(over path: String?) {
        guard path != hoveredPath else { return }
        hoveredPath = path
        hoverTask?.cancel()

        guard let path else {
            hoverAttachment?(nil)
            return
        }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled, let self, self.hoveredPath == path else { return }
            self.hoverAttachment?(path)
        }
    }
}
