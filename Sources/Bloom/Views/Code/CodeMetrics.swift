import AppKit
import BloomCore
import SwiftUI

/// Monospaced text lets a view compute its own width arithmetically instead of measuring, which
/// is what makes a single horizontal scroll view over a whole file affordable.
///
/// Every number here is derived from the font the code typography actually resolves to, rather
/// than from a point size typed in once. That is what lets the diff follow the face, size and line
/// height chosen for code instead of clipping the moment any of them grows.
@MainActor
struct CodeMetrics {
    private let face: NSFont
    private let numbers: NSFont
    private let characterWidth: CGFloat
    private let digitWidth: CGFloat
    private let naturalHeight: CGFloat
    private let height: CGFloat

    private static var cachedTypography: ThemeTypography?
    private static var cached: Self?

    static var current: Self {
        let typography = ColourThemePreference.shared.codeTypography
        if typography == cachedTypography, let cached { return cached }
        let value = Self(typography: typography)
        cachedTypography = typography
        cached = value
        return value
    }

    private init(typography: ThemeTypography) {
        face = TerminalGhostty.font(family: typography.fontFamily, size: CGFloat(typography.fontSize ?? 13))
        numbers = NSFont.monospacedDigitSystemFont(ofSize: max(9, face.pointSize - 2), weight: .regular)
        characterWidth = max(1, ("0" as NSString).size(withAttributes: [.font: face]).width)
        digitWidth = max(1, ("0" as NSString).size(withAttributes: [.font: numbers]).width)
        naturalHeight = ceil(face.ascender - face.descender + face.leading)
        height = max(16, ceil(naturalHeight * CGFloat(typography.lineHeight ?? 1.2)))
    }

    /// The font a run of code is set in.
    static var font: NSFont { current.face }
    /// The font the gutter numbers are set in, a step below the code, which is why the columns
    /// cannot be measured off `font` above.
    static var numberFont: NSFont { current.numbers }
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
    /// number in this file is measured at a scale of one, so a run pinned to this font cannot
    /// drift from `rowHeight` whatever sets that environment.
    static var measuredFont: Font { Font(font) }
    /// Width of one character of code.
    static var advance: CGFloat { current.characterWidth }
    /// Width of one digit in the gutter.
    static var numberAdvance: CGFloat { current.digitWidth }
    /// The height one line of code takes when the text system lays it out, with no air of our own
    /// added. Measured offscreen, SwiftUI gives a `Text` exactly this, which is what makes
    /// `rowSpacing` below arithmetic rather than a guess.
    static var naturalLineHeight: CGFloat { current.naturalHeight }
    /// One line of code, plus the air the line height asks for that keeps a wall of them readable.
    /// Floored at the height the diff was designed around.
    static var rowHeight: CGFloat { current.height }
    /// The air itself, which a multi-line `Text` has to be told to add between its lines.
    ///
    /// A run of lines drawn as one `Text` gets its line boxes from the text system, not from a
    /// frame, so the gutter beside it only stays level if each box is exactly `rowHeight`.
    /// **`.lineSpacing` is the only lever that works.** A paragraph style carrying
    /// `minimumLineHeight` and `maximumLineHeight` on the `AttributedString` is the obvious way to
    /// say it and SwiftUI ignores it outright: measured offscreen, three lines styled to 18 points
    /// each came back 45 points tall, the same as unstyled. `.lineSpacing(3)` came back 51, which
    /// is the 18 this wants.
    static var rowSpacing: CGFloat { rowHeight - naturalLineHeight }
    /// The `+` or `-` column. One character wide, plus its own breathing room.
    static var markerWidth: CGFloat { ceil(advance) + 4 }
    /// Four digits, which covers every file anyone reads a diff of by hand.
    ///
    /// Measured in the font the numbers are actually set in. Measured in the code font instead, a
    /// unified diff spent ten points of a 380 point column on slack either side of a four digit
    /// number, and those points come off the end of every line of code in the file.
    static var numberWidth: CGFloat { ceil(numberAdvance * 4) + gutterPadding }
    /// Between a line number and whatever sits next to it.
    static let gutterPadding: CGFloat = 4
    /// Between the marker column and the first character of code.
    static let textInset: CGFloat = 8

    /// Display columns a line occupies. `CodeColumns.count(of:)` in the core, because
    /// `DiffDocument` runs it over every line of a diff and lives there now, and a width rule
    /// with two implementations is a scroller that is right in one place and wrong in the other.
    static func columns(of line: String) -> Int { CodeColumns.count(of: line) }
}
