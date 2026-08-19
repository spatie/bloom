import AppKit

/// The line number gutter down the left of the editor.
///
/// An `NSRulerView` rather than a second scroll view or a column of SwiftUI `Text`, because the
/// ruler is the one thing AppKit already keeps pinned to a scrolling text view's layout. Numbers
/// are placed from the layout manager's line fragments, so they track the real position of each
/// line rather than an assumed row height.
///
/// Wrapping is off in this editor, so one line fragment is one logical line and the count can
/// simply increment. The line start offsets are cached and rebuilt only when the text changes,
/// which keeps scrolling off the O(file) path.
final class LineNumberRuler: NSRulerView {
    /// Between the numbers and the edges of the gutter.
    private static let padding: CGFloat = 6

    private var lineStarts: [Int] = [0]
    private var isStale = true

    /// What the gutter is painted with.
    ///
    /// Resolved by the caller and stored, never converted inside `draw`: turning a SwiftUI `Color`
    /// into an `NSColor` during a draw pass drags the SwiftUI graph into it, which is what broke
    /// the window capture the first time this ruler was written. The defaults are the AppKit
    /// colours the diff has always used, so a caller that says nothing gets exactly what it had.
    var fill: NSColor = .underPageBackgroundColor
    var rule: NSColor = .separatorColor
    var numberColor: NSColor = .tertiaryLabelColor {
        didSet { attributes[.foregroundColor] = numberColor }
    }

    private var attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(
            ofSize: max(9, CodeMetrics.font.pointSize - 1), weight: .regular
        ),
        .foregroundColor: NSColor.tertiaryLabelColor,
    ]

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        clipsToBounds = true

        // A ruler is a sibling of the clip view, not a subview of it, so scrolling does not
        // invalidate it on its own. Selector based rather than a block, because the block form
        // would have to capture this view into a `@Sendable` closure.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // How much room the scroll view has left for the ruler is only knowable once it has laid
        // itself out, which is after this editor is built. A one line run script never changes
        // afterwards, so without watching for that first layout its code stayed indented by the
        // width of the gutter on top of the gutter. Resizing the window arrives here too, which
        // is what keeps the numbers from being left behind by a shrinking box.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewDidResize),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc private func clipViewDidScroll() {
        needsDisplay = true
    }

    @objc private func clipViewDidResize() {
        alignTextToGutter()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    /// Called when the text changed. The offsets and the gutter's width both follow the number of
    /// lines, so they are recomputed together, and here rather than during a draw: changing
    /// `ruleThickness` triggers layout, and layout triggered from inside `draw` is a loop.
    func refresh() {
        isStale = true
        if let textView = clientView as? NSTextView {
            rebuildIfNeeded(textView.string as NSString)
            fitThickness()
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        let text = textView.string as NSString
        rebuildIfNeeded(text)

        // Painted rather than left to the ruler's own background, both so it matches the diff's
        // gutter and so it is certainly opaque: the text view runs underneath it.
        //
        // The fill is clipped to `bounds` by hand. On macOS a view does not clip its own drawing,
        // and the rect a ruler is handed during an offscreen render of the whole window is the
        // whole window, so filling it painted over every other view in the app.
        //
        // Already-resolved `NSColor`s, never a `Palette` value converted here: converting a
        // SwiftUI `Color` inside a draw pass drags the SwiftUI graph into it, and that broke the
        // window capture in a different way again. See `fill` and `rule`.
        let gutter = bounds
        fill.setFill()
        gutter.fill()

        rule.setFill()
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        NSRect(
            x: bounds.maxX - hairline, y: gutter.minY, width: hairline, height: gutter.height
        ).fill()

        let inset = textView.textContainerInset.height
        let origin = convert(NSPoint.zero, from: textView).y + inset

        // Start at the line owning the first visible glyph, then walk forward. Asking the layout
        // manager for a glyph index per line is cheap once layout exists, and layout for the
        // visible range is exactly what the text view has just done.
        let visible = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let firstCharacter = layoutManager
            .characterRange(forGlyphRange: visible, actualGlyphRange: nil)
            .location
        var index = line(containing: firstCharacter)

        while index < lineStarts.count {
            let start = lineStarts[index]
            guard start <= text.length else { break }

            guard let fragment = fragment(for: start, in: text, layoutManager: layoutManager)
            else { break }
            let y = origin + fragment.minY
            if y > rect.maxY { break }

            if y + fragment.height >= rect.minY {
                let label = "\(index + 1)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(
                        x: ruleThickness - size.width - Self.padding,
                        y: y + (fragment.height - size.height) / 2
                    ),
                    withAttributes: attributes
                )
            }
            index += 1
        }
    }

    /// Where one line sits, in the text view's own coordinates.
    ///
    /// The line a buffer ending in a newline leaves behind has no glyphs at all, and the layout
    /// manager holds it apart from every other line as the "extra" fragment. Asked for it the
    /// ordinary way, `glyphIndexForCharacter(at:)` runs off the end of the glyph store and hands
    /// back a zero rect, so the number for that last line was drawn at the top of the gutter,
    /// stacked on top of the 1. A script pasted in with a trailing newline is the common case, so
    /// nearly every box in the settings window showed it.
    private func fragment(
        for start: Int, in text: NSString, layoutManager: NSLayoutManager
    ) -> NSRect? {
        guard start == text.length else {
            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        // An empty buffer is the same case: line one has no glyphs either, and asking for its
        // fragment the ordinary way made AppKit log `invalid glyph index 0` on every draw of an
        // empty script field.
        guard layoutManager.extraLineFragmentTextContainer != nil else {
            // Layout has not run yet, which only happens before the first pass. Line one sits at
            // the top of the container either way, and the next draw has the real rect.
            return start == 0 ? NSRect(x: 0, y: 0, width: 0, height: CodeMetrics.rowHeight) : nil
        }
        return layoutManager.extraLineFragmentRect
    }

    /// The character offset each line starts at. Index `i` is the offset of line `i + 1` as the
    /// user counts them.
    private func rebuildIfNeeded(_ text: NSString) {
        guard isStale else { return }
        isStale = false

        var starts: [Int] = [0]
        var index = 0
        while index < text.length {
            if text.character(at: index) == 10 { starts.append(index + 1) }
            index += 1
        }
        lineStarts = starts
    }

    private func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Keep the text out from under the gutter, and out from under it exactly once.
    ///
    /// `NSScrollView` is documented to shrink its clip view to make room for a ruler and cannot be
    /// relied on to: in a full pane editor it kept the full width and the gutter was painted over
    /// the first few characters of every line, which is what insetting the text container was
    /// added to fix. Inside a form it does shrink the clip view, and the two together indented
    /// every line of a setup script by the width of the gutter twice over: a visible channel of
    /// dead space between the numbers and the code.
    ///
    /// So the room the scroll view has already made is measured rather than assumed, and only the
    /// remainder is taken out of the text container. `CodeMetrics.textInset` is added either way,
    /// because that is the air between the gutter and the first character rather than clearance.
    private func alignTextToGutter() {
        guard let textView = clientView as? NSTextView else { return }
        // Where the clip view actually begins, in the scroll view's own coordinates. Its `frame`
        // does not answer this: it reads (0, 0) whether or not the scroll view moved it, and
        // trusting it left the code indented by the gutter twice.
        let reserved = scrollView.map { $0.contentView.convert(NSPoint.zero, to: $0).x } ?? 0
        let remaining = max(0, ruleThickness - reserved)
        let inset = NSSize(
            width: remaining + CodeMetrics.textInset, height: textView.textContainerInset.height
        )
        guard textView.textContainerInset != inset else { return }
        textView.textContainerInset = inset
    }

    /// Wide enough for the largest number the file can show, so the gutter does not twitch as the
    /// user scrolls past line 1000.
    private func fitThickness() {
        let digits = max(2, String(lineStarts.count).count)
        let sample = String(repeating: "0", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: attributes).width) + Self.padding * 2
        if abs(width - ruleThickness) > 0.5 {
            ruleThickness = width
            // The room the scroll view leaves is only correct once it has re-tiled around the
            // new thickness. Safe here because this is never reached from a draw pass.
            scrollView?.tile()
        }
        // Every time, not only when the thickness moved: the room the scroll view makes for the
        // ruler is not settled when the first one of these runs.
        alignTextToGutter()
    }
}
