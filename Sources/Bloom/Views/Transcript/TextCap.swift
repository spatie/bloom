import Foundation

/// Keeps a tool's output inside what a `Text` can lay out.
///
/// A tool result can be megabytes, and SwiftUI will happily try to lay out a hundred thousand lines
/// and then stop being a usable application.
enum TextCap {
    /// Output beyond this many lines is folded away behind a button.
    static let lineCap = 500
    /// Even "show everything" has a ceiling, because a `Text` is not a pager.
    static let characterCap = 400_000

    /// Cuts a string at a line count without splitting it into an array first, because a tool
    /// result can be tens of megabytes and `split` on that allocates the whole thing twice.
    static func cap(_ text: String, lines: Int) -> (text: String, truncated: Bool) {
        var seen = 0
        var index = text.startIndex
        var characters = 0

        while index < text.endIndex {
            if characters >= characterCap {
                return (String(text[text.startIndex..<index]), true)
            }
            if text[index] == "\n" {
                seen += 1
                if seen >= lines {
                    return (String(text[text.startIndex..<index]), true)
                }
            }
            index = text.index(after: index)
            characters += 1
        }
        return (text, false)
    }
}
