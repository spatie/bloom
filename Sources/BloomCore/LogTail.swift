import Foundation

/// The last few lines of something that is still being written to.
///
/// A setup script is `composer install` and `bun install` and a database being created: thousands
/// of lines, arriving continuously. The transcript shows the end of that rather than the whole of
/// it, because the transcript is a reading surface and the full log already has a tab of its own.
///
/// Taken from the END, which is the difference between this and `TextCap`. A cap from the front is
/// right for a tool result, which is a finished thing whose first lines say what it is; a log that
/// is still running is only interesting at the bottom, where the line that is about to change is.
///
/// Written as one backwards walk over the string rather than `split(separator:)` and a suffix: the
/// log is capped at 200,000 characters and splitting it allocates every line of it to keep four.
public enum LogTail {
    /// The last `lines` lines, with trailing blank lines ignored so a log that ends in a newline
    /// does not spend one of them on nothing.
    public static func last(_ text: String, lines: Int) -> String {
        guard lines > 0 else { return "" }

        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isNewline else { break }
            end = previous
        }
        guard end > text.startIndex else { return "" }

        var start = end
        var seen = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isNewline {
                seen += 1
                if seen == lines { break }
            }
            start = previous
        }

        return String(text[start..<end])
    }

    /// The last line with anything on it, which is what a one line status shows while a script is
    /// running. Empty when the log is empty or is nothing but whitespace.
    public static func lastLine(_ text: String) -> String {
        let tail = last(text, lines: 1)
        return tail.trimmingCharacters(in: .whitespaces)
    }

    /// How many lines the log holds, counted rather than split, so a status line can say how big
    /// the thing behind the disclosure is.
    public static func lineCount(_ text: String) -> Int {
        var trimmedEnd = text.endIndex
        while trimmedEnd > text.startIndex {
            let previous = text.index(before: trimmedEnd)
            guard text[previous].isNewline else { break }
            trimmedEnd = previous
        }
        guard trimmedEnd > text.startIndex else { return 0 }

        var count = 1
        var index = text.startIndex
        while index < trimmedEnd {
            if text[index].isNewline { count += 1 }
            index = text.index(after: index)
        }
        return count
    }
}
