import AppKit
import SwiftUI
import BloomCore

/// The two directions between a draft and what the text view holds: a path in the draft is one
/// chip in the storage, and one chip in the storage is that path again.
///
/// The draft is the truth. `AttachmentDraft` says which runs of it are files, and everything here
/// does is draw those runs as a chip instead of as a path and put the path back the moment
/// anything is read out. Nothing on the AppKit side remembers that a chip is up, so an edit
/// cannot leave the two disagreeing: the storage is rebuilt from the draft, and the draft is
/// rebuilt from the storage, and both are pure.
///
/// A chip is one character. `NSTextAttachment` is what makes it one, and that is worth more than
/// the drawing: the caret cannot land inside it, backspace next to it takes the whole file away in
/// one press the way it takes a word, selecting across it selects it whole, and the text system's
/// own undo covers all three because from where it stands nothing unusual happened.
@MainActor
enum ComposerChipText {
    /// The attribute the path is carried on, beside the attachment that draws it. Read rather than
    /// the cell, so flattening asks the storage a question about text rather than about drawing.
    static let pathKey = NSAttributedString.Key("bloom.attachment.path")

    /// The draft as the text view should hold it: words as words, files as chips.
    static func storage(
        for draft: String, paths: [String], font: NSFont, color: NSColor
    ) -> NSAttributedString {
        let parsed = AttachmentDraft.parse(draft, paths: paths)
        let result = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        for segment in parsed.segments {
            switch segment {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: attributes))
            case .attachment(let path):
                result.append(chip(for: path, font: font))
            }
        }
        return result
    }

    /// One file, as the single character that stands for it.
    static func chip(for path: String, font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = AttachmentChipCell(path: path, font: font)

        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes(
            [pathKey: path, .font: font],
            range: NSRange(location: 0, length: chip.length)
        )
        return chip
    }

    /// What the text view is holding, as the draft it stands for.
    static func draft(of storage: NSAttributedString) -> String {
        var text = ""
        forEachRun(in: storage) { run in
            switch run {
            case .text(let string): text += string
            case .attachment(let path, _): text += AttachmentDraft.token(for: path)
            }
        }
        return text
    }

    /// The same, for one range of it, which is what a copy of a selection has to put on the
    /// clipboard: a path somebody can paste into a terminal, rather than the object replacement
    /// character a chip is made of.
    static func draft(of storage: NSAttributedString, in range: NSRange) -> String {
        draft(of: storage.attributedSubstring(from: range))
    }

    // MARK: - Counting in two units

    /// A position in the text view, as a position in the draft.
    ///
    /// The two disagree by however many chips lie before it: a chip is one character there and a
    /// whole path here.
    static func draftOffset(forStorage offset: Int, in storage: NSAttributedString) -> Int {
        var draft = 0
        var seen = 0
        forEachRun(in: storage) { run in
            switch run {
            case .text(let string):
                let length = (string as NSString).length
                if seen + length <= offset {
                    draft += length
                    seen += length
                } else if seen < offset {
                    draft += offset - seen
                    seen = offset
                }
            case .attachment(let path, _):
                guard seen < offset else { return }
                draft += (AttachmentDraft.token(for: path) as NSString).length
                seen += 1
            }
        }
        return draft
    }

    /// A position in the draft, as a position in the text view.
    ///
    /// A position inside a path has no answer in the text view, because there is nothing inside a
    /// chip to point at, so it is taken to the far side of it: that is where a caret put in the
    /// middle of a file's name belongs, and it is what the composer means when it says "after what
    /// I just wrote".
    static func storageOffset(forDraft offset: Int, in storage: NSAttributedString) -> Int {
        var draft = 0
        var position = 0
        var answer: Int?

        forEachRun(in: storage) { run in
            guard answer == nil else { return }
            switch run {
            case .text(let string):
                let length = (string as NSString).length
                if draft + length >= offset {
                    answer = position + (offset - draft)
                } else {
                    draft += length
                    position += length
                }
            case .attachment(let path, _):
                let length = (AttachmentDraft.token(for: path) as NSString).length
                if draft + length > offset, draft >= offset {
                    answer = position
                } else if draft + length >= offset {
                    answer = position + 1
                } else {
                    draft += length
                    position += 1
                }
            }
        }
        return answer ?? position
    }

    // MARK: - Walking it

    enum Run {
        case text(String)
        case attachment(path: String, at: Int)
    }

    /// One pass over the storage, in order, with runs of words handed over whole.
    static func forEachRun(in storage: NSAttributedString, _ body: (Run) -> Void) {
        let string = storage.string as NSString
        var pending = NSRange(location: 0, length: 0)

        func flush() {
            guard pending.length > 0 else { return }
            body(.text(string.substring(with: pending)))
            pending.length = 0
        }

        storage.enumerateAttribute(
            pathKey, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let path = value as? String else {
                if pending.length == 0 { pending.location = range.location }
                pending.length += range.length
                return
            }
            flush()
            // One character each, however many of them landed in this run: a paste of two chips
            // arrives as one range carrying one path, and each character is still one file.
            for offset in 0..<range.length {
                body(.attachment(path: path, at: range.location + offset))
            }
            pending.location = range.location + range.length
        }
        flush()
    }

    /// Every file in the storage, with the single character that stands for it.
    static func attachments(in storage: NSAttributedString) -> [(path: String, offset: Int)] {
        var found: [(String, Int)] = []
        forEachRun(in: storage) { run in
            guard case .attachment(let path, let offset) = run else { return }
            found.append((path, offset))
        }
        return found
    }
}

/// A file drawn where a word would be: the icon Finder gives its kind, then its name, on a plate.
///
/// Deliberately the same object as the chip that used to sit above the box, in everything the eye
/// checks: the same icon slot, the same corner radius, the same raised plate on the same hairline
/// border, the same name truncated in the middle. It is drawn rather than composed out of
/// `AttachmentChip`, because TextKit 1 has no way to put a view inside a line of text and
/// `usedRect(for:)`, which is what grows this box a line at a time, is TextKit 1's alone.
final class AttachmentChipCell: NSTextAttachmentCell {
    let path: String
    /// The font of the line the chip sits on, which is what it is sized against. Not `font`: an
    /// `NSCell` already has one of those and it means something else.
    private let lineFont: NSFont

    /// Everything about the chip that is a number: how big it is, where it sits against the
    /// baseline, and the two pieces `draw` places inside it.
    ///
    /// Measured once at init rather than answered on demand, because TextKit asks for the first
    /// two through `NSTextAttachmentCellProtocol`, which declares `cellSize()` and
    /// `cellBaselineOffset()` nonisolated, while the `NSCell` this inherits from puts the rest of
    /// the class on the main actor. So neither override may read `lineFont`, and no marking
    /// rescues it: `NSFont` is not `Sendable`, so it cannot be held nonisolated either. The
    /// numbers it yields are, and nothing they are measured from can move: a cell is built for one
    /// path at one font, and a font change rewrites the storage and builds new cells rather than
    /// resizing these.
    ///
    /// It is the cheaper shape as well. `cellSize()` is asked on every layout pass of the
    /// composer, and it used to build an `NSLayoutManager` and measure the filename each time.
    private nonisolated let chipSize: NSSize
    private nonisolated let baselineOffset: NSPoint
    private nonisolated let iconSize: CGFloat
    private nonisolated let nameWidth: CGFloat

    /// Room either side of the contents, and between the icon and the name.
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 4
    /// As wide as a name gets before it is cut in the middle. Enough for
    /// `Pasted 2026-08-20 at 22.29.20.png` to stay recognisable.
    private static let maxNameWidth: CGFloat = 170
    private static let cornerRadius: CGFloat = 4

    init(path: String, font: NSFont) {
        let nameFont = Self.nameFont(for: font)
        let name = (path as NSString).lastPathComponent
        let iconSize = ceil(nameFont.pointSize) + 2
        let nameWidth = min(
            ceil((name as NSString).size(withAttributes: [.font: nameFont]).width),
            Self.maxNameWidth
        )
        // Unrounded, because the plate is rounded up off it and the difference between the two is
        // what centres the plate below.
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let height = ceil(lineHeight) + 2

        self.path = path
        self.lineFont = font
        self.iconSize = iconSize
        self.nameWidth = nameWidth
        self.chipSize = NSSize(
            width: ceil(Self.padding * 2 + iconSize + Self.gap + nameWidth),
            height: height
        )
        // Where the plate sits against the baseline of the line it is on. The cell is drawn from
        // its bottom edge, so this is what centres it on the line rather than hanging it from the
        // baseline, which would push every line a chip is on further apart than the ones around it.
        self.baselineOffset = NSPoint(x: 0, y: font.descender - (height - lineHeight) / 2)

        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var filename: String { (path as NSString).lastPathComponent }

    /// The name, at the size the rest of the line is set at but a little smaller, which is what
    /// keeps a chip from being the tallest thing on its line. Static, because init has to ask it
    /// before there is a `self` to ask.
    private static func nameFont(for lineFont: NSFont) -> NSFont {
        NSFont.systemFont(ofSize: max(lineFont.pointSize - 1, 9))
    }

    private var nameAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        return [
            .font: Self.nameFont(for: lineFont),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }

    override func cellSize() -> NSSize { chipSize }

    override func cellBaselineOffset() -> NSPoint { baselineOffset }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(withFrame: cellFrame, in: controlView, characterIndex: 0)
    }

    override func draw(
        withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex: Int
    ) {
        let frame = cellFrame.insetBy(dx: 0, dy: 0.5)
        let plate = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        AttachmentChipCell.plateColor.setFill()
        plate.fill()
        AttachmentChipCell.borderColor.setStroke()
        plate.lineWidth = 1
        plate.stroke()

        let icon = FileTypeIcon.icon(for: filename)
        let side = iconSize
        let iconRect = NSRect(
            x: frame.minX + Self.padding,
            y: frame.midY - side / 2,
            width: side,
            height: side
        )
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        let name = NSAttributedString(string: filename, attributes: nameAttributes)
        let height = name.size().height
        let nameRect = NSRect(
            x: iconRect.maxX + Self.gap,
            y: frame.midY - height / 2,
            width: nameWidth,
            height: height
        )
        name.draw(with: nameRect, options: [.usesLineFragmentOrigin])
    }

    /// The chip answers a click itself, so opening a file is a click on the file rather than a
    /// trip to a menu. Handled by the text view, which is the only party that knows what a
    /// composer is for.
    override func wantsToTrackMouse() -> Bool { true }

    override func trackMouse(
        with event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard event.clickCount >= 1, let composer = controlView as? ComposerTextView else {
            return false
        }
        composer.openAttachment?(path)
        return true
    }

    // MARK: - Ground

    /// The composer's own raised plate and hairline, taken from the palette rather than spelled
    /// again here, and still resolved for whichever appearance the window is in at the moment of
    /// drawing: both are dynamic colours and converting one back to AppKit keeps it dynamic.
    static let plateColor = NSColor(Palette.surfaceRaised)
    static let borderColor = NSColor(Palette.border)
}
