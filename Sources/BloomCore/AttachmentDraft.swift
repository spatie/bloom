import Foundation

/// A draft, split into what was typed and the files named inside it.
///
/// An attachment used to be a chip in a bar above the text and a path in a list at the end of the
/// message. It is a word in the sentence now: the file lands where the caret was, the chip is
/// drawn there, and the agent is handed the path in the same place, so "have a look at
/// `.bloom/attachments/9JVKW4/shot.png` and fix the spacing" reaches it as one thought instead of
/// as a sentence with a footnote.
///
/// This is the whole of that translation and it is a pure function of the draft in both
/// directions, exactly as `SlashCommandDraft` is. Nothing remembers that a chip is up, so nothing
/// can disagree with the text about whether one should be: `parse(text).text == text` for every
/// draft there is, editing the text is editing the attachments, and what the agent receives is the
/// draft itself rather than something assembled beside it.
///
/// **The form.** A path is written inside backticks, which is how a path is written in any
/// message a person types to an agent. Three things follow from that one choice. It is
/// self-delimiting, so `.bloom/attachments/9JVKW4/Pasted 2026-08-20 at 22.29.20.png` survives its
/// own spaces in the middle of a sentence and the agent is never left guessing where the name
/// ended. It cannot be typed by accident into meaning something else. And it is already correct
/// prose: an agent reading the message sees a path in a code span, which is what it would see if
/// the user had typed one.
///
/// **What counts as one.** Either the path is Bloom's own copy, under `.bloom/attachments`, which
/// is recognisable from the text alone and is why a sent turn can draw the same chips without
/// being told anything; or it is one of `paths`, which is what the composer knows about the files
/// it copied in this session and is what lets a file that already lived in the worktree be a chip
/// too. Everything else inside backticks is what it looks like: a code span somebody typed.
public struct AttachmentDraft: Equatable, Sendable {
    /// One run of the draft: either words, or a file named in them.
    public enum Segment: Equatable, Sendable {
        case text(String)
        /// The path, without the backticks that delimit it in the draft.
        case attachment(String)

        /// The literal draft text of this run.
        public var text: String {
            switch self {
            case .text(let text): text
            case .attachment(let path): AttachmentDraft.token(for: path)
            }
        }
    }

    public var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// The literal text, which is what gets sent.
    public var text: String {
        segments.map(\.text).joined()
    }

    /// Every file named in the draft, in the order they are read in. Duplicates kept: a path the
    /// user copied twice is named twice, and the sentence is what they wrote.
    public var paths: [String] {
        segments.compactMap { segment in
            guard case .attachment(let path) = segment else { return nil }
            return path
        }
    }

    /// How a path is written into a draft.
    public static func token(for path: String) -> String { "`\(path)`" }

    /// The prefix that makes a path recognisable as Bloom's own copy without being told.
    ///
    /// The same folder `WorktreeScratch` shields, because that is the folder every attachment
    /// Bloom copies in is written to. A path under it is one this app put there.
    public static let copyPrefix = WorktreeScratch.attachments + "/"

    // MARK: - Reading

    public static func parse(_ draft: String, paths: [String] = []) -> AttachmentDraft {
        let known = Set(paths)
        var segments: [Segment] = []
        var pending = ""
        var index = draft.startIndex

        func flush() {
            guard !pending.isEmpty else { return }
            segments.append(.text(pending))
            pending = ""
        }

        while index < draft.endIndex {
            guard draft[index] == "`" else {
                pending.append(draft[index])
                index = draft.index(after: index)
                continue
            }

            let contentStart = draft.index(after: index)
            guard let closing = draft[contentStart...].firstIndex(of: "`") else {
                // An unclosed backtick is a backtick. Everything after it is words.
                pending.append(contentsOf: draft[index...])
                index = draft.endIndex
                break
            }

            let content = String(draft[contentStart..<closing])
            guard isAttachment(content, known: known) else {
                // Not a file. The opening backtick is text, and the scan resumes just after it so
                // that the character that closed this span can open the next one.
                pending.append("`")
                index = contentStart
                continue
            }

            flush()
            segments.append(.attachment(content))
            index = draft.index(after: closing)
        }

        flush()
        return AttachmentDraft(segments: segments)
    }

    /// Whether a backticked run names a file this draft is carrying.
    public static func isAttachment(_ content: String, known: Set<String> = []) -> Bool {
        guard !content.isEmpty, !content.contains("\n") else { return false }
        if known.contains(content) { return true }
        // A copy of Bloom's own, which has to name a file inside its id folder rather than being
        // the folder itself.
        guard content.hasPrefix(copyPrefix) else { return false }
        let rest = content.dropFirst(copyPrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return false }
        return slash != rest.startIndex && rest.index(after: slash) != rest.endIndex
    }

    // MARK: - Writing

    /// Where a newly attached file goes, and where the caret goes after it.
    ///
    /// Offsets are UTF-16 units, which is what a text view counts in.
    public struct Insertion: Equatable, Sendable {
        public var text: String
        public var caret: Int
    }

    /// Writes a path into the draft at `offset`, spaced so it reads as a word rather than as
    /// something glued to the one before it.
    ///
    /// A space is added on each side only where there is not one already, so dropping a file at
    /// the end of "have a look at " does not leave two, and dropping one into the middle of a word
    /// does not silently join it. The caret lands after the file, which is where the rest of the
    /// sentence is about to be typed.
    public static func inserting(
        _ path: String, into draft: String, at offset: Int
    ) -> Insertion {
        let string = draft as NSString
        let at = min(max(offset, 0), string.length)

        let before = at > 0 ? string.substring(with: NSRange(location: at - 1, length: 1)) : ""
        let after = at < string.length
            ? string.substring(with: NSRange(location: at, length: 1))
            : ""

        let lead = before.isEmpty || isBreak(before) ? "" : " "
        // A space after it even at the very end of the draft, which is what picking a file from
        // the `@` menu already writes: the next word is typed clear of the chip rather than
        // against it, and a second file dropped after this one is spaced without asking.
        let trail = isBreak(after) && !after.isEmpty ? "" : " "
        let written = lead + token(for: path) + trail

        let text = string.replacingCharacters(in: NSRange(location: at, length: 0), with: written)
        // After the file and after the space that follows it.
        return Insertion(text: text, caret: at + (written as NSString).length)
    }

    /// Several files dropped at one point, written in the order they were handed over.
    public static func inserting(
        _ paths: [String], into draft: String, at offset: Int
    ) -> Insertion {
        var result = Insertion(text: draft, caret: min(max(offset, 0), (draft as NSString).length))
        for path in paths {
            result = inserting(path, into: result.text, at: result.caret)
        }
        return result
    }

    /// Whether a character reads as a break between words, which is what decides whether a file
    /// needs a space of its own.
    private static func isBreak(_ character: String) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: - Taking one out

    /// The draft with the files this says no about taken out of it, and the sentence closed up
    /// behind them.
    ///
    /// What send does with a file that has gone missing between being attached and the turn going,
    /// and what the create sheet does with one that could not be moved into the worktree: naming a
    /// path the agent cannot read only teaches it that Bloom lies about paths.
    public func keeping(_ isKept: (String) -> Bool) -> String {
        var result = ""
        // Set when a file was dropped and the space that was written after it has to go with it,
        // or the sentence keeps a gap where the file was.
        var dropsLeadingSpace = false

        for segment in segments {
            switch segment {
            case .text(var text):
                if dropsLeadingSpace, text.hasPrefix(" ") { text.removeFirst() }
                dropsLeadingSpace = false
                result += text
            case .attachment(let path):
                guard !isKept(path) else {
                    result += segment.text
                    continue
                }
                // One space, on whichever side it was written. Taking both would join the words
                // that were on either side of the file.
                if result.hasSuffix(" ") {
                    result.removeLast()
                } else {
                    dropsLeadingSpace = true
                }
            }
        }
        return result
    }

    /// The draft with every file taken out of it: what the sentence says on its own.
    ///
    /// Used where the words are read by something other than the agent. A workspace is named after
    /// what it was asked for, and a name taken from a screenshot's path would be six characters of
    /// id and nothing anybody could recognise.
    public static func withoutAttachments(_ draft: String, paths: [String] = []) -> String {
        parse(draft, paths: paths)
            .keeping { _ in false }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
