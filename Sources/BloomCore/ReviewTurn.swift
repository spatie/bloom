import Foundation

/// What a sent review turn was made of, read back out of the message.
public struct ReviewTurnRecord: Sendable, Hashable {
    /// One comment as the transcript shows it: enough to draw a chip and open the right file,
    /// not enough to rebuild the payload, which the stored message already holds in full.
    public struct Chip: Sendable, Hashable {
        public var filePath: String
        public var side: ReviewCommentSide
        /// The line as the payload reported it, which is where the anchor resolved at send time.
        public var line: Int
        public var body: String

        public var fileName: String { (filePath as NSString).lastPathComponent }

        /// What the chip says: the file and the start of the comment, the way Conductor labels
        /// the same chip. The whole body is offered and the view truncates, because how many
        /// characters fit is a fact about the pane, not about the comment.
        public var label: String {
            let condensed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return condensed.isEmpty ? fileName : "\(fileName) \(condensed)"
        }

        public init(filePath: String, side: ReviewCommentSide, line: Int, body: String) {
            self.filePath = filePath
            self.side = side
            self.line = line
            self.body = body
        }
    }

    /// What was typed in the composer alongside the comments. Empty when the comments were the
    /// whole request.
    public var message: String
    public var chips: [Chip]

    public init(message: String, chips: [Chip]) {
        self.message = message
        self.chips = chips
    }
}

/// The pair that makes a review turn a chip in the transcript instead of a page of scaffolding.
///
/// `compose` is thin on purpose: `ReviewPromptContext` already knows how to resolve and render,
/// and this is only the seam that names the whole operation. `split` is its reader, in the same
/// file for the reason `AttachmentTrailer` keeps its own pair together: the two are one format,
/// and a parser kept anywhere else drifts from the generator the first time either is touched.
///
/// `split` recognises the shape the DEFAULT template renders, derived from the registry at run
/// time rather than copied here, so an edit to the template updates the reader with it. A turn
/// composed through a customised template comes back nil and the transcript shows the full text,
/// which is honest: Bloom cannot un-render prose it did not write. The same holds for turns sent
/// before the template's wording last changed. That trade is deliberate and is the one
/// `AttachmentTrailer` documents: strict recognition, and full text rather than a wrong guess at
/// the first line that does not fit.
public enum ReviewTurn {
    /// The turn that goes to the agent: the typed message and every attached comment, resolved
    /// against the worktree and rendered through the review template.
    ///
    /// Reads files (through the context's resolver), so it belongs off the main actor.
    public static func compose(
        message: String,
        comments: [ReviewComment],
        worktreePath: String?,
        template: String
    ) -> String {
        ReviewPromptContext(message: message, comments: comments, worktreePath: worktreePath)
            .render(template: template).text
    }

    // MARK: - Reading a sent turn back

    /// The template's own prose between `{{message}}` and `{{comments}}`, with the blank lines
    /// that frame it. Empty when the template stops being the shape this reader understands,
    /// which turns `split` off rather than letting it guess.
    private static let scaffold: [String] = {
        var lines = PromptRegistry.definition(for: .review).defaultTemplate
            .components(separatedBy: "\n")
        guard lines.first == PromptTemplate.token(PromptRegistry.Review.message),
              lines.last == PromptTemplate.token(PromptRegistry.Review.comments)
        else { return [] }
        lines.removeFirst()
        lines.removeLast()
        while lines.first == "" { lines.removeFirst() }
        while lines.last == "" { lines.removeLast() }
        return lines
    }()

    /// The typed message and the chips, if `text` is a review turn the default template wrote.
    public static func split(_ text: String) -> ReviewTurnRecord? {
        guard !scaffold.isEmpty else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.count > scaffold.count else { return nil }

        // The scaffold is looked for as a whole run of lines, `{{count}}` matched as digits.
        // First match wins: the only way an earlier copy exists is the message quoting a previous
        // review turn, and a quoted scaffold produces a failed payload parse and a nil below
        // rather than a wrong split.
        var start: Int?
        for candidate in 0...(lines.count - scaffold.count) {
            let run = lines[candidate..<(candidate + scaffold.count)]
            if zip(run, scaffold).allSatisfy({ matches($0, pattern: $1) }) {
                start = candidate
                break
            }
        }
        // `compose` always writes a message line (the spelled-out "no message" when nothing was
        // typed) and a blank before the scaffold, so a scaffold at the top is somebody else's
        // text.
        guard let start, start >= 2, lines[start - 1] == "" else { return nil }

        var message = lines[..<(start - 1)].joined(separator: "\n")
        if message == ReviewPromptContext.noMessage { message = "" }

        var payload = Array(lines[(start + scaffold.count)...])
        while payload.first == "" { payload.removeFirst() }

        guard let chips = chips(from: payload), !chips.isEmpty else { return nil }
        return ReviewTurnRecord(message: message, chips: chips)
    }

    /// Whether one sent line is one scaffold line, with `{{count}}` standing for any number.
    private static func matches(_ line: String, pattern: String) -> Bool {
        guard let token = pattern.range(of: PromptTemplate.token(PromptRegistry.Review.count))
        else { return line == pattern }

        let prefix = pattern[..<token.lowerBound]
        let suffix = pattern[token.upperBound...]
        guard line.count > prefix.count + suffix.count,
              line.hasPrefix(prefix), line.hasSuffix(suffix) else { return false }
        let middle = line.dropFirst(prefix.count).dropLast(suffix.count)
        return !middle.isEmpty && middle.allSatisfy(\.isNumber)
    }

    // MARK: - The payload's own grammar

    private static let filePrefix = "## "
    private static let linePrefix = "### Line "
    private static let oldSideSuffix = ", on the removed side of the diff"

    /// Reads the chips out of what `ReviewPayload.text` wrote: `## file` headings, `### Line n`
    /// headings, an optional provenance line, an optional fenced snippet, and the body last.
    ///
    /// Returns nil at the first line that fits none of those, so a message that merely resembles
    /// a payload is left alone. The one reading this cannot defend against is a comment body
    /// whose own paragraph starts with `## ` or `### Line `, which parses as an extra chip; the
    /// sent text is untouched either way, so the cost is a chip too many in the transcript and
    /// never a word lost.
    private static func chips(from lines: [String]) -> [ReviewTurnRecord.Chip]? {
        var chips: [ReviewTurnRecord.Chip] = []
        var file: String?
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.isEmpty {
                index += 1
                continue
            }
            if line.hasPrefix(filePrefix) {
                let path = String(line.dropFirst(filePrefix.count))
                guard !path.isEmpty else { return nil }
                file = path
                index += 1
                continue
            }
            if isTruncationTail(line) {
                index += 1
                continue
            }
            guard let (number, side) = heading(line), let file else { return nil }
            index += 1
            let body = readBody(lines, from: &index)
            chips.append(
                ReviewTurnRecord.Chip(filePath: file, side: side, line: number, body: body)
            )
        }
        return chips
    }

    /// `### Line 12`, or `### Line 12, on the removed side of the diff`.
    private static func heading(_ line: String) -> (line: Int, side: ReviewCommentSide)? {
        guard line.hasPrefix(linePrefix) else { return nil }
        var rest = line.dropFirst(linePrefix.count)
        var side = ReviewCommentSide.new
        if rest.hasSuffix(oldSideSuffix) {
            rest = rest.dropLast(oldSideSuffix.count)
            side = .old
        }
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber), let number = Int(rest) else { return nil }
        return (number, side)
    }

    /// `...and 3 more comments not shown.`, which `ReviewPayload.text` appends past its limit.
    private static func isTruncationTail(_ line: String) -> Bool {
        guard line.hasPrefix("...and ") else { return false }
        let rest = line.dropFirst("...and ".count)
        for suffix in [" more comment not shown.", " more comments not shown."]
        where rest.hasSuffix(suffix) {
            let number = rest.dropLast(suffix.count)
            return !number.isEmpty && number.allSatisfy(\.isNumber)
        }
        return false
    }

    /// Everything under one line heading: skip the provenance and the snippet, keep the body.
    /// Leaves `index` on the blank line before the next heading, or past the end.
    private static func readBody(_ lines: [String], from index: inout Int) -> String {
        while index < lines.count, lines[index].isEmpty { index += 1 }

        // The provenance is one parenthesised line about the anchor, written by
        // `ReviewPayload.provenance` and recognised by its one constant phrase rather than by
        // three copied sentences. A body that opens with the same phrase in parentheses loses
        // that paragraph from its chip excerpt, and from nowhere else.
        if index < lines.count, lines[index].hasPrefix("("), lines[index].hasSuffix(")"),
           lines[index].contains("the comment was written") {
            index += 1
            while index < lines.count, lines[index].isEmpty { index += 1 }
        }

        // The snippet's fence is at least three backticks and closes with its own opener.
        if index < lines.count, lines[index].count >= 3,
           lines[index].allSatisfy({ $0 == "`" }) {
            let fence = lines[index]
            index += 1
            while index < lines.count, lines[index] != fence { index += 1 }
            if index < lines.count { index += 1 }
            while index < lines.count, lines[index].isEmpty { index += 1 }
        }

        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.isEmpty {
                // A blank ends the body only when a new heading or the tail follows; the body
                // itself may hold blank lines, because a multi-paragraph comment is still one
                // comment.
                var lookahead = index + 1
                while lookahead < lines.count, lines[lookahead].isEmpty { lookahead += 1 }
                if lookahead >= lines.count { break }
                let next = lines[lookahead]
                if next.hasPrefix(filePrefix) || heading(next) != nil || isTruncationTail(next) {
                    break
                }
            }
            body.append(line)
            index += 1
        }
        while body.last == "" { body.removeLast() }
        return body.joined(separator: "\n")
    }
}
