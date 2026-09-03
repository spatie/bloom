import AppKit
import BloomCore
import SwiftUI

/// Monospaced text lets a view compute its own width arithmetically instead of measuring, which
/// is what makes a single horizontal scroll view over a whole file affordable.
///
/// Every number here is derived from the font `Typo.code` actually resolves to, rather than from a
/// point size typed in once. That is what lets the diff follow the user's text size instead of
/// clipping the moment they make text larger.
enum CodeMetrics {
    /// The font `Typo.code` resolves to: the monospaced face at the callout text style's size.
    nonisolated(unsafe) static let font: NSFont = {
        let size = NSFont.preferredFont(forTextStyle: .callout).pointSize
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }()

    /// The font the gutter numbers are set in: `Typo.codeTiny`, one rung below the code, which is
    /// why the columns cannot be measured off `font` above.
    nonisolated(unsafe) static let numberFont: NSFont = {
        let size = NSFont.preferredFont(forTextStyle: .footnote).pointSize
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }()

    /// `font` as SwiftUI sees it, which is what a run of code has to be set in.
    ///
    /// **Not `Typo.code`, and the difference is measurable rather than theoretical.** `Typo.code`
    /// is a TEXT STYLE rung, `.callout` at the monospaced design, and SwiftUI does not add
    /// `.lineSpacing` to a text style at face value: measured offscreen, twenty-one lines of it
    /// asked for three points of spacing came out 17.1375 points apart, where the same string in
    /// the same face at a fixed point size came out at exactly 18. Both render identical glyphs at
    /// the same size, so nothing about the page changes; only the line advance does, and a run
    /// gets its height from that rather than from a frame. The first version of `DiffRunView`
    /// used the rung and the gutter had slipped two whole rows by line forty, which is what the
    /// `diff-run` gallery page exists to catch.
    ///
    /// It also settles a second question. `Typo.code` multiplies by `\.fontScale`, and every
    /// number in this file is measured at a scale of one. Nothing that draws a diff sets that
    /// environment today (`ReviewPaneView` scopes it to the composer), but a run pinned to this
    /// font cannot drift from `rowHeight` even if one day something does.
    static let measuredFont = Font(font)

    /// Width of one character in `Typo.code`.
    static let advance: CGFloat = advance(of: font, fallback: 7.2)

    /// Width of one digit in the gutter.
    static let numberAdvance: CGFloat = advance(of: numberFont, fallback: 6)

    private static func advance(of font: NSFont, fallback: CGFloat) -> CGFloat {
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        return width > 0 ? width : fallback
    }

    /// The height one line of `Typo.code` takes when the text system lays it out, with no air of
    /// our own added. Measured offscreen at the callout size, SwiftUI gives a `Text` exactly this,
    /// which is what makes `rowSpacing` below arithmetic rather than a guess.
    static let naturalLineHeight: CGFloat = ceil(font.ascender - font.descender + font.leading)

    /// One line of code, plus the small amount of air that keeps a wall of them readable. Floored
    /// at the height the diff was designed around so the default appearance is unchanged.
    static let rowHeight: CGFloat = max(16, naturalLineHeight + 3)

    /// The air itself, which a multi-line `Text` has to be told to add between its lines.
    ///
    /// A run of lines drawn as one `Text` gets its line boxes from the text system, not from a
    /// frame, so the gutter beside it only stays level if each box is exactly `rowHeight`.
    /// **`.lineSpacing` is the only lever that works.** A paragraph style carrying
    /// `minimumLineHeight` and `maximumLineHeight` on the `AttributedString` is the obvious way to
    /// say it and SwiftUI ignores it outright: measured offscreen, three lines styled to 18 points
    /// each came back 45 points tall, the same as unstyled. `.lineSpacing(3)` came back 51, which
    /// is the 18 this wants.
    ///
    /// Never negative: `rowHeight` is this plus three whenever the floor above is not in play, and
    /// the floor only ever raises it.
    static let rowSpacing: CGFloat = rowHeight - naturalLineHeight

    /// The `+` or `-` column. One character wide, plus its own breathing room.
    static let markerWidth: CGFloat = ceil(advance) + 4

    /// Four digits, which covers every file anyone reads a diff of by hand.
    ///
    /// Measured in the font the numbers are actually set in. Measured in the code font instead, a
    /// unified diff spent ten points of a 380 point column on slack either side of a four digit
    /// number, and those points come off the end of every line of code in the file.
    static let numberWidth: CGFloat = ceil(numberAdvance * 4) + gutterPadding

    /// Between a line number and whatever sits next to it.
    static let gutterPadding: CGFloat = 4
    /// Between the marker column and the first character of code.
    static let textInset: CGFloat = 8

    /// Display columns a line occupies. `CodeColumns.count(of:)` in the core, because
    /// `DiffDocument` runs it over every line of a diff and lives there now, and a width rule
    /// with two implementations is a scroller that is right in one place and wrong in the other.
    static func columns(of line: String) -> Int { CodeColumns.count(of: line) }
}
