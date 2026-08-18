import AppKit

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

    /// Width of one character in `Typo.code`.
    static let advance: CGFloat = {
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        return width > 0 ? width : 7.2
    }()

    /// One line of code, plus the small amount of air that keeps a wall of them readable. Floored
    /// at the height the diff was designed around so the default appearance is unchanged.
    static let rowHeight: CGFloat = max(16, ceil(font.ascender - font.descender + font.leading) + 3)

    /// The `+` or `-` column. One character wide, plus its own breathing room.
    static let markerWidth: CGFloat = ceil(advance) + 4

    /// Four digits, which covers every file anyone reads a diff of by hand.
    static let numberWidth: CGFloat = ceil(advance * 4) + gutterPadding

    /// Between a line number and whatever sits next to it.
    static let gutterPadding: CGFloat = 4
    /// Between the marker column and the first character of code.
    static let textInset: CGFloat = 8

    /// Display columns a line occupies, counting a tab as four so the width estimate does not
    /// fall short on indented code.
    static func columns(of line: String) -> Int {
        var count = 0
        for character in line {
            count += character == "\t" ? 4 : 1
        }
        return count
    }
}
