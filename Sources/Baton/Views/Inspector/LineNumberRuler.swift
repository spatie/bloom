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

    private lazy var attributes: [NSAttributedString.Key: Any] = [
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
        moveTextClear(of: 40)

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
    }

    @objc private func clipViewDidScroll() {
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

        // The gutter is painted here rather than left to the ruler's default, both so it matches
        // the diff's gutter and so it is guaranteed opaque: the text view runs underneath it.
        // The two AppKit colours `Palette.diffGutter` and `Palette.border` resolve to, used
        // directly: converting a SwiftUI `Color` inside an AppKit draw pass drags the SwiftUI
        // graph into it, and doing that broke the app's own offscreen window capture.
        // Intersected with `bounds`, and `clipsToBounds` set in the initialiser. On macOS a view
        // does not clip its own drawing by default, and the rect handed to a ruler during an
        // offscreen render of the whole window is the whole window: filling it painted over every
        // other view in the app.
        let gutter = rect.intersection(bounds)
        NSColor.underPageBackgroundColor.setFill()
        gutter.fill()
        NSColor.separatorColor.setFill()
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        NSRect(x: bounds.maxX - hairline, y: gutter.minY, width: hairline, height: gutter.height).fill()

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

            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
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

    /// Keep the text out from under the gutter.
    ///
    /// `NSScrollView` is documented to shrink its clip view to make room for a ruler, and here it
    /// does not: the clip view keeps the full width and the gutter is painted over the first few
    /// characters of every line. Setting `contentInsets` instead only moves the ruler. What does
    /// work is insetting the text container itself, which also means scrolling sideways slides the
    /// code under an opaque gutter, the way a code editor should behave anyway.
    private func moveTextClear(of width: CGFloat) {
        guard let textView = clientView as? NSTextView else { return }
        textView.textContainerInset = NSSize(
            width: width + CodeMetrics.textInset, height: textView.textContainerInset.height
        )
    }

    /// Wide enough for the largest number the file can show, so the gutter does not twitch as the
    /// user scrolls past line 1000.
    private func fitThickness() {
        let digits = max(2, String(lineStarts.count).count)
        let sample = String(repeating: "0", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: attributes).width) + Self.padding * 2
        guard abs(width - ruleThickness) > 0.5 else { return }
        ruleThickness = width
        moveTextClear(of: width)
    }
}
