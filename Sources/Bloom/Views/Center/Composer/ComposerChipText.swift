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
    ///
    /// The ground is named by the caller because the same chip is now drawn on two very different
    /// ones: the composer's sunken grey, and the accent fill of a sent turn. See
    /// `AttachmentChipCell.Ground`, which is where the second one's numbers and their measurements
    /// are written down.
    static func chip(
        for path: String, font: NSFont, ground: AttachmentChipCell.Ground = .composer
    ) -> NSAttributedString {
        let attachment = FileChipAttachment(path: path, font: font, ground: ground)
        attachment.attachmentCell = AttachmentChipCell(path: path, font: font, ground: ground)

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

/// A chip that is equal to another chip for the same file, drawn the same way.
///
/// **Nothing here is about drawing, and it is not optional.** `NSAttributedString.isEqual(to:)`
/// compares the attachment objects in the two strings, and `NSObject`'s answer to that is identity,
/// so two strings built a frame apart from the same sentence came out unequal for ever. Both places
/// that hold one of these strings decide whether to touch their text storage by comparing the new
/// string against what they already have, and a comparison that is always false means the storage
/// is replaced on every update: in the transcript that is once per streamed chunk, and replacing
/// the storage takes the reader's selection with it. A turn with a path in it could not be
/// selected while the agent was answering.
///
/// Equal means the same file at the same size on the same ground, which is exactly the set of
/// things that changes what is drawn.
final class FileChipAttachment: NSTextAttachment {
    let path: String
    private let font: NSFont
    private let ground: AttachmentChipCell.Ground

    init(path: String, font: NSFont, ground: AttachmentChipCell.Ground) {
        self.path = path
        self.font = font
        self.ground = ground
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FileChipAttachment else { return false }
        return other.path == path && other.font == font && other.ground == ground
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(path)
        hasher.combine(font)
        return hasher.finalize()
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
    /// What the chip is drawn on, as the three colours that depend on it.
    ///
    /// Plain `NSColor`s rather than anything dynamic for the bubble's ground, and that is not
    /// laziness. An `NSColor` inside a text view resolves against the WINDOW's appearance, and the
    /// user's bubble names `colorScheme` dark whatever the page is doing, so a dynamic pair here
    /// would resolve on the light ramp inside a surface that is dark in both appearances. It is
    /// the same trap `Palette.bubbleTextSelection` is a hard value for, and for the same reason.
    struct Ground: Equatable {
        var plate: NSColor
        var border: NSColor
        var ink: NSColor

        /// Above the text field: the composer's own raised plate and hairline, taken from the
        /// palette rather than spelled again here, and still resolved for whichever appearance the
        /// window is in at the moment of drawing. Both are dynamic colours and converting one back
        /// to AppKit keeps it dynamic.
        @MainActor static let composer = Ground(
            plate: NSColor(Palette.surfaceRaised), border: NSColor(Palette.border), ink: .labelColor
        )

        /// Inside a sent turn, on the accent fill `UserTurnRowView` draws.
        ///
        /// **The plate is DARKER than the bubble it sits in, where every other chip on this fill
        /// is lighter, and it is darker because the lighter one cannot carry text.**
        /// `AttachmentChip`, `Chip` and `DiffStatLabel` all sit on the accent fill as the inverted
        /// ink at twenty percent, which over Spatie Blue composites to `#4791A9`: white on that is
        /// 3.56 to 1, under the 4.5 floor for body text. Nothing rescues a white plate here.
        /// Ten percent is 4.32, still short; five percent is 4.76 and passes, but at 1.09 against
        /// the fill it is a pill nobody can see, which is not a chip, it is a rumour of one.
        ///
        /// So this one goes the other way. Spatie Blue at three quarters is `#13586E`, it carries
        /// the same white ink the sentence around it is set in at 7.93 to 1, and it stands off the
        /// fill at 1.51, which is the separation the twenty percent plate already had (1.47). It
        /// reads as a recess in the bubble rather than as a card lying on top of it, which is what
        /// a path inside a sentence is.
        ///
        /// One value rather than a pair, because `Palette.accentFill` is one value in both
        /// appearances: these ratios are the ratios in light and in dark alike.
        ///
        /// The two treatments do not meet in practice. A turn draws these pills for the paths in
        /// its sentence and `AttachmentChip` for the paths in its trailer, and nothing has written
        /// a trailer since a file became a word in the sentence. See `AttachmentTrailer`.
        @MainActor static let userBubble = Ground(
            plate: NSColor(rgb: 0x13586E),
            // The plate's own edge, lifted off the plate rather than off the page: 2.34 against
            // what it encloses and 1.55 against the bubble outside it. A hairline in
            // `Palette.border` disappears into a fill this saturated, which is the same finding
            // `AttachmentChip.stroke` records.
            border: NSColor(rgb: 0x6692A1),
            ink: .white
        )
    }

    let path: String
    private let ground: Ground
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

    init(path: String, font: NSFont, ground: Ground = .composer) {
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
        self.ground = ground
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
            .foregroundColor: ground.ink,
            .paragraphStyle: paragraph,
        ]
    }

    override func cellSize() -> NSSize { chipSize }

    override func cellBaselineOffset() -> NSPoint { baselineOffset }

    /// The fallback TextKit does not take: it draws an attachment through the overload below,
    /// which is the only one that says which character it is drawing. `NSNotFound` rather than
    /// zero, so a chip reached this way cannot be mistaken for the one the pointer is on when
    /// that one happens to be the first character of the draft.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(withFrame: cellFrame, in: controlView, characterIndex: NSNotFound)
    }

    override func draw(
        withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex: Int
    ) {
        let frame = cellFrame.insetBy(dx: 0, dy: 0.5)
        let plate = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        ground.plate.setFill()
        plate.fill()
        ground.border.setStroke()
        plate.lineWidth = 1
        plate.stroke()

        let side = iconSize
        let iconRect = NSRect(
            x: frame.minX + Self.padding,
            y: frame.midY - side / 2,
            width: side,
            height: side
        )
        // The file's own icon, unless the pointer is on the chip, in which case the slot is the
        // close control instead. A symbol that would not load falls back to the icon rather than
        // to an empty slot.
        let mark = (isRemovable(from: controlView, at: characterIndex) ? close : nil)
            ?? FileTypeIcon.icon(for: filename)
        mark.draw(
            in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil
        )

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

    // MARK: - Taking it off

    /// Whether this chip is showing its close control, which is the pointer resting on it inside a
    /// composer. A chip in a sent turn is drawn by another view entirely and has nothing to
    /// remove: the prompt the agent read named that file, so the transcript cannot un-name it.
    private func isRemovable(from controlView: NSView?, at characterIndex: Int) -> Bool {
        guard let composer = controlView as? ComposerTextView else { return false }
        return composer.isChipHovered(at: characterIndex)
    }

    /// The close control, which takes the icon's place rather than a slot of its own.
    ///
    /// The width is measured once at init and TextKit has already laid the line out around it, so
    /// a control beside the name would have to come out of the name. Swapping the icon costs the
    /// name nothing, keeps the chip exactly the width it had so the line does not reflow under the
    /// pointer, and is what `AttachmentChip` and `SlashCommandChip` already do above the box.
    ///
    /// **A drawn X on a plate, not `xmark.circle.fill`.** That symbol knocks its X out of a filled
    /// disc, so the X is a hole showing whatever is behind the chip: grey on grey at eleven
    /// points, which is a smudge rather than a control.
    ///
    /// That was found and fixed on `AttachmentChip`, and this chip kept the smudge, because the
    /// two are the same object drawn by two renderers and only one of them is a view. The chip
    /// above the box was the one read; the chip *inside* the box, which is the one a file dropped
    /// into the composer actually becomes, was the one complained about. They read one set of
    /// numbers now: see `ChipRemoveMark`, and `ChipRemoveImage` for the drawing.
    ///
    /// The composer's own ground, because a sent turn is never removable: `isRemovable` wants a
    /// `ComposerTextView` and the bubble is not one. So the disc is `Palette.surface` under a
    /// `surfaceRaised` chip, which is the step `AttachmentChip` takes, and it is not a fourth
    /// member of `Ground` because the other ground would have to invent a value it can never draw.
    ///
    /// Built per draw rather than held: one chip shows it, only while the pointer is on it, and it
    /// is a disc with a glyph on it.
    private var close: NSImage? {
        ChipRemoveImage.of(
            diameter: iconSize,
            ink: ground.ink,
            plate: NSColor(Palette.surface),
            border: ground.border,
            label: "Remove \(filename)"
        )
    }

    /// Where a click takes the file off rather than opening it: the icon's slot and the padding
    /// around it, up to halfway across the gap before the name. Wider than the glyph on purpose,
    /// which is fourteen points in a twenty point pill, and stopping short of the name because
    /// reading the name is what tells you which file you are about to remove.
    private func closeRect(in frame: NSRect) -> NSRect {
        NSRect(
            x: frame.minX,
            y: frame.minY,
            width: Self.padding + iconSize + Self.gap / 2,
            height: frame.height
        )
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
        // Only where the control is actually showing. Without that, the click that makes an
        // inactive window key would remove a file whose X the reader never saw: the tracking area
        // is `.activeInKeyWindow`, so nothing has hovered yet.
        if isRemovable(from: controlView, at: charIndex),
           closeRect(in: cellFrame).contains(composer.convert(event.locationInWindow, from: nil)) {
            composer.removeAttachment(at: charIndex)
            return true
        }
        composer.openAttachment?(path)
        return true
    }
}
