import Foundation

/// How wide a line of code is, in characters rather than in points.
///
/// Monospaced text lets a view compute its own width arithmetically instead of measuring it, which
/// is what makes one horizontal scroll view over a whole file affordable. The count is the half of
/// that arithmetic which has nothing to do with a font, so it lives here, where the pass that runs
/// it over every line of a diff can be tested.
public enum CodeColumns {
    /// A tab counts as four, so the width estimate does not fall short on indented code.
    ///
    /// Four rather than eight, and rather than a real tab stop: the editors this diff is read
    /// beside render a tab as four, and a stop-aware count would be right about the glyphs and
    /// wrong about the scroller, which is drawn on a fixed advance per column.
    public static func count(of line: String) -> Int {
        var count = 0
        for character in line {
            count += character == "\t" ? 4 : 1
        }
        return count
    }
}
