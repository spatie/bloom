import Foundation

/// A passage of an agent's answer, quoted into the draft of the next prompt.
///
/// **Plain Markdown quote lines rather than a chip.** Every agent reads `>` as "this is what you
/// said", the sent bubble draws it as the quote it is, and the owner can trim it in the composer
/// like any other text, which is most of the point: one sentence out of a long answer, with a
/// question under it.
public enum ReplyQuote {
    /// The draft with the selection quoted at the end of it, and a blank line left under the quote
    /// for the caret.
    ///
    /// At the end rather than at the caret, for `ComposerHandoff`'s reason: the selection was made
    /// somewhere else, and the caret is wherever it was last left. Quoting twice quotes twice, each
    /// under the last, which is how a reply to two passages is written.
    public static func appending(_ selection: String, to draft: String) -> String? {
        var lines = selection
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        // A bare `>` on a blank line keeps a quote of two paragraphs one quote.
        let quote = lines
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")

        var head = draft
        while let last = head.last, last.isWhitespace { head.removeLast() }
        return (head.isEmpty ? "" : head + "\n\n") + quote + "\n\n"
    }
}
