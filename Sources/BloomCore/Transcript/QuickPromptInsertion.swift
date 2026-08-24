import Foundation

/// What choosing a quick prompt does to the draft: its text goes in at the caret, and nothing is
/// sent.
///
/// **Insert, never send.** Every one of these starts a turn against a real worktree, and a list
/// somebody arrows through is the wrong place to be one keystroke away from that. So the prompt is
/// a starting point: it can be edited, appended to, and a second one can be stacked after it.
///
/// It goes in as plain text and not as a chip. Bloom draws chips for files and for a `/command`
/// because each of those stands for something the CLI resolves later, and a chip is a thing you can
/// only remove. A quick prompt stands for nothing. It is the words, so it has to be editable where
/// it lands.
///
/// A pure function rather than a decision taken in the composer, because it is the one part of this
/// with edge cases worth pinning: an empty box, a caret in the middle of a sentence, a draft ending
/// mid word, a draft ending in a space, and a draft ending in a newline.
public enum QuickPromptInsertion {
    /// Where the words went, and where the caret goes after them.
    ///
    /// Offsets are UTF-16 units, which is what a text view counts in and what the composer's
    /// `caret` binding holds.
    public struct Result: Equatable, Sendable {
        public var text: String
        public var caret: Int

        public init(text: String, caret: Int) {
            self.text = text
            self.caret = caret
        }
    }

    /// Writes a prompt into `draft` at `caret`.
    public static func inserting(
        _ prompt: QuickPrompt, into draft: String, at caret: Int
    ) -> Result {
        inserting(prompt.text, into: draft, at: caret)
    }

    /// Writes `prompt` into `draft` at `caret`, spaced so it reads as its own sentence rather than
    /// as something glued to the word before it.
    ///
    /// **The separator is a single space, and only where there is not already a break.** The same
    /// rule `AttachmentDraft.padding` applies to a file, asked of the same two characters, because
    /// a draft must never end up with two gaps where the writer put one: dropping a prompt at the
    /// end of "and then " leaves one space, and a draft ending in a newline gets nothing at all,
    /// since the line break is already a bigger break than a space. A blank line was the other
    /// candidate and is wrong here: most of these are appended to half a sentence somebody is
    /// still writing, and a prompt that always started its own paragraph would have to be joined
    /// up by hand every time.
    ///
    /// The trailing space exists only when there are words after the caret, so a prompt inserted
    /// mid sentence does not run into the rest of it. At the end of the draft there is nothing to
    /// run into, and a trailing space there would leave the caret one character clear of what was
    /// just inserted.
    ///
    /// The caret lands at the end of the inserted words, which is where the next thing is typed.
    public static func inserting(_ prompt: String, into draft: String, at caret: Int) -> Result {
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let string = draft as NSString
        let at = min(max(caret, 0), string.length)
        guard !body.isEmpty else { return Result(text: draft, caret: at) }

        // Whole characters rather than one UTF-16 unit each side. A draft ending in an emoji ends
        // in a surrogate pair, and the unit sitting against the caret is half of one: read on its
        // own it is not a character at all, so the question "is that a space" cannot be asked of
        // it and the prompt was written hard against the emoji.
        let before = at > 0
            ? string.substring(with: string.rangeOfComposedCharacterSequence(at: at - 1))
            : ""
        let after = at < string.length
            ? string.substring(with: string.rangeOfComposedCharacterSequence(at: at))
            : ""

        let lead = isBreak(before) ? "" : " "
        let trail = isBreak(after) ? "" : " "
        let written = lead + body + trail
        let text = string.replacingCharacters(in: NSRange(location: at, length: 0), with: written)

        // Before the trailing space rather than after it: what was inserted ends with the prompt's
        // own last character, and that is where somebody carries on typing.
        let caret = at + ((lead + body) as NSString).length
        return Result(text: text, caret: caret)
    }

    /// Whether the character beside the insertion already separates two words. An absent character
    /// counts, which is what makes the start and the end of the draft take no space of their own.
    private static func isBreak(_ character: String) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
