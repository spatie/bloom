import AppKit
import BloomCore

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

    /// Width of one character in `Typo.code`.
    static let advance: CGFloat = advance(of: font, fallback: 7.2)

    /// Width of one digit in the gutter.
    static let numberAdvance: CGFloat = advance(of: numberFont, fallback: 6)

    private static func advance(of font: NSFont, fallback: CGFloat) -> CGFloat {
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        return width > 0 ? width : fallback
    }

    /// One line of code, plus the small amount of air that keeps a wall of them readable. Floored
    /// at the height the diff was designed around so the default appearance is unchanged.
    static let rowHeight: CGFloat = max(16, ceil(font.ascender - font.descender + font.leading) + 3)

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
