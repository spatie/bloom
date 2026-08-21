import Foundation

// MARK: - Side

/// Which column of the diff a note was left on.
///
/// Kept even after the note is resolved against the working tree, because it is the difference
/// between "this line you wrote is wrong" and "you should not have deleted this line", and the
/// agent cannot recover that from the text alone.
public enum ReviewCommentSide: String, Sendable, Hashable, CaseIterable, Codable {
    case old
    case new
}

// MARK: - Anchor

/// Where a note points, and enough evidence to still find that place after the file moves.
///
/// A line number on its own is worthless here. The agent this review is for edits files while the
/// review window is open, so by the time the notes are sent, "line 34" may be a different line,
/// or no line. So the anchor stores the number *and* the text that was on it, plus a few lines of
/// either side, and re-finds the line by content when the numbers no longer agree. This is the
/// same trick a merge tool uses: text identifies, numbers only hint.
///
/// The context lines earn their storage twice. They disambiguate a `}` that occurs four hundred
/// times in the file, and they are the snippet the prompt payload shows the agent when the file
/// cannot be read at all (worktree moved, file deleted, note restored on another machine). That
/// second job is why they are captured at comment time rather than computed on demand.
///
/// Rejected alternatives: storing a byte offset (invalidated by any edit above it, and unusable
/// for re-finding), storing a content hash of the whole file (tells you it changed, never where
/// the line went), and re-diffing old against new at send time (needs both blobs, and the old
/// blob is gone the moment the agent writes the file again).
public struct ReviewCommentAnchor: Sendable, Hashable, Codable {
    /// How many lines are kept on each side. Three is enough to make a brace or a blank line
    /// unique in practice while keeping a note small enough that a hundred of them still fit in a
    /// prompt.
    public static let contextRadius = 3

    /// The line number as the reviewer saw it, one-based, in `side`'s numbering.
    public var line: Int
    /// The exact text of that line when the note was written, without its diff marker.
    public var text: String
    /// Up to `contextRadius` lines immediately above, in file order.
    public var before: [String]
    /// Up to `contextRadius` lines immediately below, in file order.
    public var after: [String]

    public init(line: Int, text: String, before: [String] = [], after: [String] = []) {
        self.line = line
        self.text = text
        self.before = before
        self.after = after
    }

    /// Capture an anchor from the file's own lines. `line` is one-based.
    public static func make(
        line: Int,
        in lines: [String],
        radius: Int = contextRadius
    ) -> ReviewCommentAnchor {
        let index = line - 1
        guard lines.indices.contains(index) else {
            return ReviewCommentAnchor(line: line, text: "")
        }
        let start = max(0, index - radius)
        let end = min(lines.count - 1, index + radius)
        return ReviewCommentAnchor(
            line: line,
            text: lines[index],
            before: Array(lines[start..<index]),
            after: Array(lines[(index + 1)...end])
        )
    }

    /// Capture an anchor straight from a rendered hunk, which is what the diff view has in hand.
    ///
    /// Only lines belonging to `side` are considered, so the neighbours are the file's neighbours
    /// and not the interleaved additions and deletions the view happens to be drawing. Returns nil
    /// when the hunk has no such line, which means the caller was asked to comment on padding.
    public static func make(
        line: Int,
        side: ReviewCommentSide,
        in hunk: DiffHunk,
        radius: Int = contextRadius
    ) -> ReviewCommentAnchor? {
        let sideLines = hunk.lines.filter { $0.kind != .noNewline && number(of: $0, on: side) != nil }
        guard let index = sideLines.firstIndex(where: { number(of: $0, on: side) == line }) else {
            return nil
        }
        let start = max(0, index - radius)
        let end = min(sideLines.count - 1, index + radius)
        return ReviewCommentAnchor(
            line: line,
            text: sideLines[index].text,
            before: sideLines[start..<index].map(\.text),
            after: sideLines[(index + 1)...end].map(\.text)
        )
    }

    private static func number(of diffLine: DiffLine, on side: ReviewCommentSide) -> Int? {
        side == .old ? diffLine.oldNumber : diffLine.newNumber
    }
}

// MARK: - Resolution

/// What became of an anchor when it was matched against the file as it stands now.
public struct AnchorResolution: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        /// The anchored text is still on the line it was written against.
        case exact
        /// Found, but at a different line number. `line` is where it is now.
        case shifted
        /// Not found, or found in so many equally plausible places that picking one would be a
        /// guess. `line` is the original number, clamped into the file, so a view can still scroll
        /// somewhere sensible.
        case outdated
    }

    public var line: Int
    public var status: Status

    public var isOutdated: Bool { status == .outdated }

    public init(line: Int, status: Status) {
        self.line = line
        self.status = status
    }
}

public extension ReviewCommentAnchor {
    /// Re-find this anchor in a file's current lines.
    ///
    /// Every line whose text matches exactly is a candidate. Candidates are scored on how much of
    /// the stored context still sits around them, weighted towards the nearest neighbours because
    /// an edit two lines away is far more likely than one directly adjacent. Ties go to whichever
    /// candidate moved least, since code usually shifts rather than teleports.
    ///
    /// Matching is exact rather than trimmed or fuzzy on purpose: a note that says "this
    /// indentation is wrong" must not silently re-attach to the reindented line and then report
    /// itself as unchanged. Whitespace is content here.
    func resolve(in lines: [String]) -> AnchorResolution {
        let clamped = max(1, min(line, max(lines.count, 1)))

        var candidates: [Int] = []
        for (index, current) in lines.enumerated() where current == text {
            candidates.append(index + 1)
        }
        guard !candidates.isEmpty else {
            return AnchorResolution(line: clamped, status: .outdated)
        }

        if candidates.contains(line) {
            // Still at home. Even if an identical line elsewhere scores higher, nothing observable
            // says the note moved, and claiming it did would relabel a file nobody touched.
            return AnchorResolution(line: line, status: .exact)
        }

        var best = candidates[0]
        var bestScore = contextScore(at: best, in: lines)
        for candidate in candidates.dropFirst() {
            let score = contextScore(at: candidate, in: lines)
            let closer = abs(candidate - line) < abs(best - line)
            if score > bestScore || (score == bestScore && closer) {
                best = candidate
                bestScore = score
            }
        }

        // Several identical lines and not one shred of surrounding evidence. Any pick would be a
        // coin flip, and a note pinned to the wrong line is worse than a note that admits it lost
        // its place, because the agent cannot tell the two apart.
        if bestScore == 0, candidates.count > 1 {
            return AnchorResolution(line: clamped, status: .outdated)
        }

        return AnchorResolution(line: best, status: .shifted)
    }

    func resolve(in contents: String) -> AnchorResolution {
        resolve(in: ReviewCommentAnchor.split(contents))
    }

    /// Splits on newlines the way a text editor counts lines: a trailing newline does not create a
    /// phantom last line, which would put every anchor near the end of the file off by one.
    static func split(_ contents: String) -> [String] {
        var lines = contents.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// How much of the stored neighbourhood survives around a one-based candidate line. Nearer
    /// neighbours count for more, so a candidate with the directly adjacent line intact beats one
    /// that only matches three lines out.
    private func contextScore(at candidate: Int, in lines: [String]) -> Int {
        var score = 0
        let radius = max(before.count, after.count)

        for (offset, expected) in before.reversed().enumerated() {
            let index = candidate - 2 - offset
            guard lines.indices.contains(index), lines[index] == expected else { continue }
            score += radius - offset
        }
        for (offset, expected) in after.enumerated() {
            let index = candidate + offset
            guard lines.indices.contains(index), lines[index] == expected else { continue }
            score += radius - offset
        }
        return score
    }
}

// MARK: - Comment

/// One line-anchored note taken during a review.
///
/// Working state of a workspace, not a document: it lives as long as the review does, and its
/// whole purpose is to be handed to the agent and then let go of.
public struct ReviewComment: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var workspaceID: WorkspaceID
    /// Repository-relative, as the diff spells it, so it means the same thing in the prompt as it
    /// does to `git` and to the agent's own file tools.
    public var filePath: String
    public var side: ReviewCommentSide
    public var anchor: ReviewCommentAnchor
    public var body: String
    public var createdAt: Date
    /// Whether this note still rides along with the next message. Detaching keeps the note (the
    /// reviewer may want to re-attach or re-read it) while taking it out of the payload.
    public var isAttached: Bool

    public var line: Int { anchor.line }

    /// What a chip shows, and the last path component the prompt payload never uses, since the
    /// agent needs the full path to open the file.
    public var fileName: String { (filePath as NSString).lastPathComponent }

    public init(
        id: String = newID(),
        workspaceID: WorkspaceID,
        filePath: String,
        side: ReviewCommentSide = .new,
        anchor: ReviewCommentAnchor,
        body: String,
        createdAt: Date = Date(),
        isAttached: Bool = true
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.filePath = filePath
        self.side = side
        self.anchor = anchor
        self.body = body
        self.createdAt = createdAt
        self.isAttached = isAttached
    }
}

public extension Array where Element == ReviewComment {
    /// The order every consumer uses, so a payload rendered twice from the same notes is the same
    /// text, and a list redrawn after an edit does not jump. Path, then line, then age, then id:
    /// the last two only matter for two notes on one line, where the older one was written first
    /// and should read first.
    func sortedForReview() -> [ReviewComment] {
        sorted {
            if $0.filePath != $1.filePath { return $0.filePath < $1.filePath }
            if $0.anchor.line != $1.anchor.line { return $0.anchor.line < $1.anchor.line }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }
}

// MARK: - Composer summary

/// The short labels the composer shows for the notes attached to the next message.
public enum ReviewCommentSummary {
    /// How many lines a single-file label spells out before it starts counting instead.
    public static let lineLimit = 3

    /// One note, as Conductor writes it: the file's name and the line, `Thing.swift +34`.
    ///
    /// The sign carries the side. `+` is the line as it stands after the change, `-` is the line
    /// as it was before, which is the only way a chip can distinguish a note about new code from a
    /// note about code that was removed.
    public static func chip(for comment: ReviewComment) -> String {
        "\(comment.fileName) \(comment.side == .old ? "-" : "+")\(comment.anchor.line)"
    }

    /// The label for everything currently attached.
    public static func label(for comments: [ReviewComment]) -> String {
        let ordered = comments.sortedForReview()
        guard let first = ordered.first else { return "" }
        guard ordered.count > 1 else { return chip(for: first) }

        let sameFile = ordered.allSatisfy { $0.filePath == first.filePath }
        if sameFile, ordered.count <= lineLimit {
            let marks = ordered.map { "\($0.side == .old ? "-" : "+")\($0.anchor.line)" }
            return "\(first.fileName) \(marks.joined(separator: " "))"
        }

        // Past a few notes the individual numbers stop being readable in a chip, so the first one
        // keeps its shape and the rest become a count. Naming the first is what makes the chip
        // still feel anchored to something rather than turning into an abstract "5 comments".
        return "\(chip(for: first)) and \(ordered.count - 1) more"
    }
}
