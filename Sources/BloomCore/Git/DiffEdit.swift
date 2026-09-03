import Foundation

/// The lines of the file one in-place edit stands for, and the text they hold.
///
/// The numbers are the diff's NEW side, one-based, which is also the file's own numbering: the
/// new side of a diff and the file in the worktree are the same document. That is the whole of
/// the mapping, and it is only true while the file still says at those numbers what the diff
/// printed there, which is what `DiffEdit.region` checks before ever handing one of these out.
public struct DiffEditRegion: Sendable, Hashable {
    /// One-based new-side number of the first line the editor covers.
    public let firstLine: Int
    /// The file's own lines over that span, as they were when the editor opened. Never empty.
    public let lines: [String]

    public init(firstLine: Int, lines: [String]) {
        self.firstLine = firstLine
        self.lines = lines
    }

    public var lineCount: Int { lines.count }
    public var lastLine: Int { firstLine + lines.count - 1 }

    /// What goes into the box. No trailing newline: the newline between two lines is a separator
    /// here, and the one at the end of the file belongs to the file rather than to this region.
    public var text: String { lines.joined(separator: "\n") }

    /// Whether the box has been changed. The Save control is offered on this and nothing else, so
    /// a save can never be a write of the bytes that are already there.
    public func isEdited(_ typed: String) -> Bool { typed != text }
}

/// Why an edit could not be opened, or could not be spliced back.
///
/// Every case but `oldSide` is the same event seen from a different angle: the agent wrote the
/// file while the reader was looking at a diff of it. That event is expected here rather than
/// exceptional, which is why each case carries the line it was noticed at and says so in words a
/// reader can act on.
public enum DiffEditRefusal: Error, Sendable, Equatable {
    /// A removed line. It is not in the file any more, so there is nothing to type into.
    case oldSide
    /// The file is shorter than the diff says, so the line is not there to edit.
    case gone(line: Int)
    /// The file holds something else at that number now. The diff on screen is stale.
    case moved(line: Int)
    /// A block of new lines longer than `DiffEdit.lineLimit`.
    case tooManyLines(Int)
}

extension DiffEditRefusal: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .oldSide:
            "A removed line is not in the file any more, so there is nothing to edit."
        case let .gone(line):
            "The file does not have line \(line) any more. It has changed since this diff was drawn."
        case let .moved(line):
            "Line \(line) no longer holds what this diff shows. The file changed while you were "
                + "reading it, so nothing was opened for editing."
        case let .tooManyLines(count):
            "That is \(count) new lines in a row, more than the \(DiffEdit.lineLimit) this box "
                + "takes. Open the file itself to change something this size."
        }
    }
}

/// Editing the new side of a diff in place: which lines an edit may cover, where they are in the
/// file, and what happens when the agent writes the file underneath one.
///
/// **The reason all of it is here rather than in the diff view.** The worktree this edits is the
/// one an agent is working in, so every rule below is really a rule about two writers. Which
/// lines may be edited decides what a wrong answer would destroy; how a region maps back to the
/// file decides whether a save lands on the lines the reader was looking at; and the check that
/// the file still says what the diff printed is the only thing standing between a stale diff and
/// an edit written over somebody else's work. A decision taken inside a view is a decision
/// nothing can test, and these are the three worth testing most.
///
/// **What is offered, and what is not.** Only the new side. An old-side line was deleted, so
/// there is no text in the file to change and no honest place to put the caret. On the new side:
///
/// - An added line opens the whole contiguous block of added lines around it, because that block
///   is the change the reader is looking at and a rename or a fixed typo usually spans a few
///   lines of it.
/// - A context line, printed or revealed between hunks, opens as itself and nothing else.
///   Widening a context click to its neighbours would put a hundred unchanged lines in a box
///   nobody asked to edit.
///
/// **Nothing here writes.** `region` reads a file's text and `apply` returns a new one; putting
/// the result on disk is `FileEditor.write`, which re-reads the file and refuses when it no
/// longer holds what the editor was opened on. That refusal is the guard that matters, because
/// the check below happens at open time and the agent goes on working afterwards.
public enum DiffEdit {
    /// How many lines one in-place box takes. Past this the reader wants the file, not a band in
    /// the middle of a diff: the box would be taller than the pane, and everything above and
    /// below it would be pushed off screen while it was open.
    public static let lineLimit = 200

    // MARK: - Locating

    /// The region an edit begun at `line` covers, checked against the file as it is now.
    ///
    /// - Parameters:
    ///   - line: a one-based new-side line number, which the file numbers the same way.
    ///   - hunks: the parsed diff on screen. A line no hunk printed is a revealed context line,
    ///     which is as editable as any other and is taken from the file alone.
    ///   - fileText: the whole file, read at this moment. The file is the truth; the diff only
    ///     says where to look.
    public static func region(
        at line: Int, in hunks: [DiffHunk], fileText: String
    ) throws(DiffEditRefusal) -> DiffEditRegion {
        let contents = Contents(of: fileText)
        let printed = newSide(of: hunks)

        let covered = try span(at: line, printed: printed)
        guard covered.count <= lineLimit else { throw DiffEditRefusal.tooManyLines(covered.count) }
        guard covered.lowerBound >= 1, covered.upperBound <= contents.lines.count else {
            throw DiffEditRefusal.gone(line: covered.upperBound)
        }

        // The diff's line numbers are worth exactly as much as the agreement between the diff and
        // the file at those numbers. Ten lines inserted above by the agent moves every number
        // below them, and an edit saved against the old numbers would land on code the reader
        // never saw. So each line of the span has to still hold what the diff printed for it.
        for number in covered {
            guard let shown = printed[number] else { continue }
            guard contents.lines[number - 1] == shown.text else {
                throw DiffEditRefusal.moved(line: number)
            }
        }

        return DiffEditRegion(
            firstLine: covered.lowerBound,
            lines: Array(contents.lines[(covered.lowerBound - 1)..<covered.upperBound])
        )
    }

    /// Which lines the edit covers, from the diff alone.
    private static func span(
        at line: Int, printed: [Int: DiffLine]
    ) throws(DiffEditRefusal) -> ClosedRange<Int> {
        guard line >= 1 else { throw DiffEditRefusal.gone(line: line) }
        // A line no hunk printed is one the reader revealed between two hunks. It came off the
        // worktree in the first place, so it is a file line like any other and stands alone.
        guard let target = printed[line] else { return line...line }

        switch target.kind {
        case .context:
            return line...line
        case .addition:
            var first = line
            var last = line
            while printed[first - 1]?.kind == .addition { first -= 1 }
            while printed[last + 1]?.kind == .addition { last += 1 }
            return first...last
        case .deletion, .noNewline:
            // Neither carries a new-side number, so neither can be reached through `printed`.
            // Answered anyway rather than left to a `fatalError`: a hand-built hunk in a test, or
            // a patch this parser has not met, must refuse rather than trap.
            throw DiffEditRefusal.oldSide
        }
    }

    /// Every line the diff prints on the new side, by its number. The marker rows carry no
    /// number and are not in it.
    private static func newSide(of hunks: [DiffHunk]) -> [Int: DiffLine] {
        var result: [Int: DiffLine] = [:]
        for hunk in hunks {
            for line in hunk.lines where line.kind != .noNewline {
                guard let number = line.newNumber else { continue }
                result[number] = line
            }
        }
        return result
    }

    // MARK: - Splicing

    /// The whole file with `edited` in place of `region`.
    ///
    /// `fileText` must be the text the region was located in, and the check that it still is
    /// costs one comparison of a handful of lines. It is not the save's guard, which is
    /// `FileEditor.write` re-reading the file: it is the guard on this function's own argument,
    /// so a caller that mixes up two files or two regions gets a refusal rather than a splice at
    /// the right numbers of the wrong document.
    ///
    /// An emptied box is one blank line and not a deletion of the region. The two are a single
    /// newline apart and only one of them is recoverable by typing: a reader who wanted the lines
    /// gone can select them in the file itself, whereas a reader whose blank line silently
    /// removed the lines around it has no way back.
    public static func apply(
        _ edited: String, of region: DiffEditRegion, to fileText: String
    ) throws(DiffEditRefusal) -> String {
        var contents = Contents(of: fileText)
        let first = region.firstLine - 1
        let last = region.lastLine - 1
        guard first >= 0, last < contents.lines.count else {
            throw DiffEditRefusal.gone(line: region.lastLine)
        }
        guard Array(contents.lines[first...last]) == region.lines else {
            throw DiffEditRefusal.moved(line: region.firstLine)
        }
        contents.lines.replaceSubrange(first...last, with: edited.components(separatedBy: "\n"))
        return contents.text
    }

    // MARK: - The other writer

    /// What to tell a reader whose file has moved on while their box is open, or nil while it has
    /// not.
    ///
    /// Said while it is happening rather than at the save, because the save is the moment the
    /// reader finds out they cannot have what they typed, and finding out then is finding out too
    /// late to do anything except copy it out. Nothing is disabled on the strength of this: it is
    /// read from a poll, the poll can be behind, and `FileEditor.write` is the check that actually
    /// decides. A warning that turns out to be wrong costs a sentence; a Save button wrongly
    /// disabled costs the edit.
    ///
    /// - Parameters:
    ///   - filename: the last path component, which is what the reader calls the file.
    ///   - baseline: the file's whole text as the editor was opened on it.
    ///   - contents: the file's whole text now, or nil if it is not there any more.
    public static func staleWarning(
        filename: String, baseline: String, contents: String?
    ) -> String? {
        guard let contents else {
            return "\(filename) is no longer on disk. Saving will be refused, so copy anything "
                + "you want to keep."
        }
        guard contents != baseline else { return nil }
        return "\(filename) changed on disk while you were editing. Saving will be refused, so "
            + "copy what you typed, cancel, and edit the new version."
    }

    // MARK: - Closing the box on typed text

    /// Cancelling an edit somebody has typed into, and what they are asked first.
    ///
    /// The same argument as `ReviewCommentDiscard`, which is the shape this follows: Cancel and
    /// Escape both close the box, Escape arrives from hands that were dismissing something else,
    /// and there is no undo anywhere in the app that brings the text back. A box holding exactly
    /// what the file holds has nothing to lose and closes on the press, because a question with
    /// nothing behind it teaches people to click through questions.
    public enum Discard {
        /// Whether to ask at all.
        public static func needed(closing typed: String, of region: DiffEditRegion) -> Bool {
            region.isEdited(typed)
        }

        public static let title = "Discard these edits?"
        /// Consequences rather than "are you sure?", and the first half is the reassuring half:
        /// nothing has been written, so the file is not part of what is lost.
        public static let message = "The file is not changed, and what you typed is not kept."
        public static let confirmLabel = "Discard"
        /// Named for what keeping means. "Cancel" is the word on the button that asked.
        public static let cancelLabel = "Keep Editing"
    }

    // MARK: - Lines

    /// A file split into lines, and whether it ended with a newline, kept together so a splice
    /// puts the file back exactly as it found it.
    ///
    /// The split is `ReviewCommentAnchor.split`'s, deliberately: the review bands number the
    /// file's lines that way and this numbers them the same, so a comment and an edit on one line
    /// of one file cannot come to two different opinions about which line that is. The trailing
    /// newline is what this adds, because a comment only reads the lines and this writes them
    /// back: dropped, every save would strip the last newline off the file, and every one of them
    /// would show up as a whole-file change in the next diff.
    struct Contents {
        var lines: [String]
        var endsWithNewline: Bool

        init(of text: String) {
            var lines = text.components(separatedBy: "\n")
            endsWithNewline = lines.count > 1 && lines.last == ""
            if endsWithNewline { lines.removeLast() }
            self.lines = lines
        }

        var text: String {
            lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        }
    }
}
