import Foundation

/// One note, rendered for the agent: where it points now, and the code around that place.
///
/// Public because the diff view needs the same three facts to draw an inline comment band, and
/// resolving twice (once for the band, once for the payload) is how the two end up disagreeing.
public struct ReviewCommentRender: Sendable, Hashable {
    public struct SnippetLine: Sendable, Hashable {
        public var number: Int
        public var text: String
        /// The line the note is about. Exactly one line in a snippet has this set.
        public var isAnchor: Bool

        public init(number: Int, text: String, isAnchor: Bool) {
            self.number = number
            self.text = text
            self.isAnchor = isAnchor
        }
    }

    public var comment: ReviewComment
    public var resolution: AnchorResolution
    /// The lines shown to the agent, with the numbers they carry now.
    public var snippet: [SnippetLine]

    public init(comment: ReviewComment, resolution: AnchorResolution, snippet: [SnippetLine]) {
        self.comment = comment
        self.resolution = resolution
        self.snippet = snippet
    }
}

/// Turns a review into the block of text that rides along with the next message.
///
/// Everything here is pure. Reading the working tree is the caller's job and arrives as a lookup
/// closure, which is what makes the whole payload testable without a worktree, and what lets the
/// renderer fall back to the snapshot stored on the anchor when a file cannot be read.
public enum ReviewPayload {
    /// Notes shown before the rest are counted. A payload is prepended to a real message, so it
    /// cannot be allowed to eat the context window on its own.
    public static let commentLimit = 60

    /// How many lines of code accompany each note. Wider than the anchor's own radius would be
    /// wasteful; narrower and the agent has to open the file to understand a one-line remark.
    public static let snippetRadius = ReviewCommentAnchor.contextRadius

    /// Reads a repository-relative path out of a worktree. Returns nil for anything it cannot
    /// decode as text, which is the same answer as "the agent already deleted it".
    public static func worktreeReader(root: String) -> (String) -> [String]? {
        { path in
            let full = (root as NSString).appendingPathComponent(path)
            guard let contents = try? String(contentsOfFile: full, encoding: .utf8) else { return nil }
            return ReviewCommentAnchor.split(contents)
        }
    }

    /// Resolve every note against the file as it stands now, in payload order.
    public static func renders(
        for comments: [ReviewComment],
        currentLines: (String) -> [String]? = { _ in nil }
    ) -> [ReviewCommentRender] {
        var cache: [String: [String]?] = [:]
        return comments.sortedForReview().map { comment in
            let lines: [String]?
            if let known = cache[comment.filePath] {
                lines = known
            } else {
                lines = currentLines(comment.filePath)
                cache[comment.filePath] = lines
            }
            return render(comment, in: lines)
        }
    }

    /// The text a prompt template drops into its `{{comments}}` slot.
    public static func text(
        for comments: [ReviewComment],
        currentLines: (String) -> [String]? = { _ in nil },
        limit: Int = commentLimit
    ) -> String {
        let all = renders(for: comments, currentLines: currentLines)
        let shown = Array(all.prefix(limit))
        guard !shown.isEmpty else { return "" }

        var blocks: [String] = []
        var currentFile: String?

        for render in shown {
            let comment = render.comment
            if comment.filePath != currentFile {
                blocks.append("## \(comment.filePath)")
                currentFile = comment.filePath
            }
            blocks.append(block(for: render))
        }

        let remaining = all.count - shown.count
        if remaining > 0 {
            blocks.append("...and \(remaining) more comment\(remaining == 1 ? "" : "s") not shown.")
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - One note

    private static func block(for render: ReviewCommentRender) -> String {
        let comment = render.comment
        var parts = ["### Line \(render.resolution.line)\(sideSuffix(comment.side))"]

        if let note = provenance(for: render) { parts.append(note) }
        if let snippet = fenced(render.snippet) { parts.append(snippet) }

        // The body is last and unlabelled below a heading that already said what it is about, so a
        // multi-line note reads as the reviewer wrote it instead of being folded into a field.
        parts.append(comment.body)
        return parts.joined(separator: "\n\n")
    }

    /// Said out loud rather than left for the agent to notice, because a line number that no
    /// longer means what it meant is the one thing that can make a correct note act like a wrong
    /// one.
    private static func provenance(for render: ReviewCommentRender) -> String? {
        let original = render.comment.anchor.line
        switch render.resolution.status {
        case .exact:
            return nil
        case .shifted:
            // Same number after a `.shifted` verdict means the file was never read, so the snapshot
            // is what is being shown. Claiming it moved would be a sentence about an edit nobody saw.
            guard render.resolution.line != original else {
                return "(this file could not be read just now, so the code below is how it looked "
                    + "when the comment was written)"
            }
            return "(this line has moved since the comment was written: it was line \(original))"
        case .outdated:
            return "(the file has changed and this exact line is gone; it was line \(original) "
                + "when the comment was written, and the code below is how it looked then)"
        }
    }

    private static func sideSuffix(_ side: ReviewCommentSide) -> String {
        // Only the old side is called out. Saying "new side" on every note would be noise, since
        // the overwhelming majority of a review is about the code as it now stands.
        side == .old ? ", on the removed side of the diff" : ""
    }

    /// A fence long enough to survive the file's own backticks, which matters the moment somebody
    /// reviews Markdown or a doc comment containing a code block.
    private static func fenced(_ lines: [ReviewCommentRender.SnippetLine]) -> String? {
        guard !lines.isEmpty else { return nil }

        let width = String(lines.map(\.number).max() ?? 0).count
        let body = lines.map { line in
            let number = String(line.number)
            let padded = String(repeating: " ", count: max(0, width - number.count)) + number
            // No trailing space on a blank line: the snippet is read as text, and an invisible
            // difference between a blank line here and a blank line in the file is a needless one.
            let prefix = "\(line.isAnchor ? ">" : " ") \(padded) |"
            return line.text.isEmpty ? prefix : "\(prefix) \(line.text)"
        }.joined(separator: "\n")

        var longestRun = 0
        var run = 0
        for character in body {
            run = character == "`" ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(fence)\n\(body)\n\(fence)"
    }

    private static func render(_ comment: ReviewComment, in lines: [String]?) -> ReviewCommentRender {
        guard let lines, !lines.isEmpty else {
            return ReviewCommentRender(
                comment: comment,
                // With no file to check against, the stored snapshot is all there is. Calling that
                // `.exact` would claim the line was verified, so it is reported as the guess it is.
                resolution: AnchorResolution(line: comment.anchor.line, status: .shifted),
                snippet: storedSnippet(comment.anchor)
            )
        }

        let resolution = comment.anchor.resolve(in: lines)
        let snippet: [ReviewCommentRender.SnippetLine] = resolution.isOutdated
            ? storedSnippet(comment.anchor)
            : liveSnippet(around: resolution.line, in: lines)
        return ReviewCommentRender(comment: comment, resolution: resolution, snippet: snippet)
    }

    private static func liveSnippet(
        around line: Int,
        in lines: [String]
    ) -> [ReviewCommentRender.SnippetLine] {
        let index = line - 1
        guard lines.indices.contains(index) else { return [] }
        let start = max(0, index - snippetRadius)
        let end = min(lines.count - 1, index + snippetRadius)
        return (start...end).map {
            ReviewCommentRender.SnippetLine(number: $0 + 1, text: lines[$0], isAnchor: $0 == index)
        }
    }

    /// The snapshot taken when the note was written. Numbered from the anchor outwards, so the
    /// numbers still line up with what the reviewer was looking at even though they no longer
    /// describe the file.
    private static func storedSnippet(
        _ anchor: ReviewCommentAnchor
    ) -> [ReviewCommentRender.SnippetLine] {
        var lines: [ReviewCommentRender.SnippetLine] = []
        for (offset, text) in anchor.before.enumerated() {
            let number = anchor.line - anchor.before.count + offset
            guard number > 0 else { continue }
            lines.append(ReviewCommentRender.SnippetLine(number: number, text: text, isAnchor: false))
        }
        lines.append(
            ReviewCommentRender.SnippetLine(number: anchor.line, text: anchor.text, isAnchor: true)
        )
        for (offset, text) in anchor.after.enumerated() {
            lines.append(ReviewCommentRender.SnippetLine(
                number: anchor.line + 1 + offset, text: text, isAnchor: false
            ))
        }
        return lines
    }
}

/// The facts the review prompt is rendered against.
///
/// Mirrors `PullRequestPromptContext`: a plain value, so what the agent is told can be checked
/// without a store or a worktree.
public struct ReviewPromptContext: Sendable, Hashable {
    /// Sent when the reviewer attaches notes and types nothing. A heading with nothing under it
    /// reads to the agent as an instruction that got cut off, so it is spelled out instead.
    public static let noMessage = "(no message: the comments below are the whole request)"

    public var message: String
    public var comments: String
    public var count: Int

    public init(message: String, comments: String, count: Int) {
        self.message = message
        self.comments = comments
        self.count = count
    }

    /// Build straight from the notes, resolving each against the worktree it belongs to.
    ///
    /// Reads files, so a large review belongs off the main actor.
    public init(message: String, comments: [ReviewComment], worktreePath: String?) {
        let noFiles: (String) -> [String]? = { _ in nil }
        let reader = worktreePath.map { ReviewPayload.worktreeReader(root: $0) } ?? noFiles
        self.init(
            message: message,
            comments: ReviewPayload.text(for: comments, currentLines: reader),
            count: comments.count
        )
    }

    public var values: [String: String] {
        [
            PromptRegistry.Review.message: message.isEmpty ? Self.noMessage : message,
            PromptRegistry.Review.comments: comments,
            PromptRegistry.Review.count: String(count),
        ]
    }

    public func render(template: String) -> PromptRender {
        PromptTemplate.render(template, values: values)
    }
}
