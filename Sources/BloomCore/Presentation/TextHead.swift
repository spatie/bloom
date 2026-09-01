import Foundation

/// The first lines of a piece of text, cut to what a hover card can hold.
///
/// It was the head of `SourceHead`, which reads a file for the card over a chip that names one,
/// and it moved the moment a chip could stand for words that are in the message rather than in a
/// file. The merge instructions have no file to read, and a card that cut them a different way
/// from the pull request instructions beside them would be two answers to one question inside the
/// same popover.
///
/// Here rather than beside the view for the usual reason: both numbers are the sort of thing that
/// gets nudged, and neither of them is a drawing.
public enum TextHead {
    /// How many lines are shown, and how wide a line may be before it is cut.
    ///
    /// Both are about the card rather than about the text: past this it stops being a glance and
    /// starts being a reader. Twenty four lines at the code rung fit inside the card's own height
    /// cap with room to spare.
    public static let lines = 24
    public static let columns = 160

    /// The first lines of `text`, and whether there were more, or nil for text with nothing in it
    /// to show.
    public static func head(
        of text: String, lines: Int = TextHead.lines, columns: Int = TextHead.columns
    ) -> (lines: [String], truncated: Bool)? {
        // Text with no newline at the end must not gain a blank last line, and text that is
        // nothing but whitespace has nothing to show.
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            all.removeLast()
        }
        guard !all.isEmpty else { return nil }

        let truncated = all.count > lines
        let head = all.prefix(lines).map { line -> String in
            // Tabs drawn at their own width make one long line as wide as the screen.
            let expanded = line.replacingOccurrences(of: "\t", with: "    ")
            return expanded.count > columns
                ? String(expanded.prefix(columns)) + "\u{2026}"
                : expanded
        }
        return (head, truncated)
    }
}
