import Foundation

// MARK: - Spot

/// One commentable place in a rendered diff: a side and a line number in that side's counting.
///
/// A struct rather than a tuple because it is view state: the diff view holds "the editor is open
/// at this spot" across rebuilds, and a tuple can be neither `Hashable` state nor a dictionary
/// key without spelling itself out at every use.
public struct ReviewSpot: Sendable, Hashable, Codable {
    public var side: ReviewCommentSide
    public var line: Int

    public init(side: ReviewCommentSide, line: Int) {
        self.side = side
        self.line = line
    }
}

/// Several consecutive lines of one side, which is what dragging down the gutter selects.
///
/// **One side, always.** A drag that began on a deletion and ended on an addition has crossed
/// between two versions of the file, and there is no such thing as a range that spans both: the
/// old side is the merge base's copy and the new side is the worktree's. So a selection is built
/// from two spots only when they agree about which side they are on, and the caller that offers
/// the drag filters by side before it ever gets here (see `DiffCommentSpot`).
///
/// Normalised on the way in, because a drag upwards is as ordinary as a drag downwards and every
/// reader of this type would otherwise have to remember to sort the two numbers itself.
public struct ReviewSelection: Sendable, Hashable {
    public var side: ReviewCommentSide
    /// The lower of the two line numbers, which is where the note anchors.
    public var start: Int
    /// The higher of the two, which is the line the band sits under.
    public var end: Int

    public init(side: ReviewCommentSide, start: Int, end: Int) {
        self.side = side
        self.start = min(start, end)
        self.end = max(start, end)
    }

    /// One line, which is what pressing the gutter `+` without dragging means.
    public init(_ spot: ReviewSpot) {
        self.init(side: spot.side, start: spot.line, end: spot.line)
    }

    /// The range a drag from one spot to another covers, or nil when the two are not on the same
    /// side of the diff.
    public init?(from: ReviewSpot, to: ReviewSpot) {
        guard from.side == to.side else { return nil }
        self.init(side: from.side, start: from.line, end: to.line)
    }

    /// How many lines the note covers, which is what the anchor stores.
    public var span: Int { end - start + 1 }

    public var isRange: Bool { end > start }

    /// Where the note anchors: the first line, in this side's numbering.
    public var anchor: ReviewSpot { ReviewSpot(side: side, line: start) }

    /// Every line the selection covers, which is what a diff tints while the drag is live and
    /// what it tints again once the note exists.
    public var spots: [ReviewSpot] {
        (start...end).map { ReviewSpot(side: side, line: $0) }
    }

    public func contains(_ spot: ReviewSpot) -> Bool {
        spot.side == side && spot.line >= start && spot.line <= end
    }
}

public extension DiffLine {
    /// Where a comment left on this rendered line attaches, or nil for a line that is not code.
    ///
    /// A deletion is only addressable on the old side, because that is the only side it exists
    /// on. Everything else anchors to the new side, context lines included: a remark on an
    /// unchanged line is a remark about the file as it stands, and anchoring it to the old
    /// numbering would make the agent go looking for it in a version of the file it can no
    /// longer read.
    var reviewSpot: ReviewSpot? {
        switch kind {
        case .deletion: oldNumber.map { ReviewSpot(side: .old, line: $0) }
        case .addition, .context: newNumber.map { ReviewSpot(side: .new, line: $0) }
        case .noNewline: nil
        }
    }
}

// MARK: - Capture

public enum ReviewCapture {
    /// The anchor for a comment left at `spot`, with the evidence `ReviewCommentAnchor` wants.
    ///
    /// The hunks are asked first, because their neighbours are the diff's own record of the file
    /// and the old side exists nowhere else. A new-side line the hunks do not contain is not a
    /// refusal though: the diff view reveals unchanged lines between hunks on demand, those lines
    /// come from the worktree copy, and a comment on one of them is as legitimate as any other.
    /// They fall through to the file's own lines. Only an old-side line no hunk printed returns
    /// nil, which means the caller asked to comment on something that was never on screen.
    public static func anchor(
        at selection: ReviewSelection,
        hunks: [DiffHunk],
        fileLines: [String]?
    ) -> ReviewCommentAnchor? {
        for hunk in hunks {
            if let anchor = ReviewCommentAnchor.make(
                line: selection.start, span: selection.span, side: selection.side, in: hunk
            ) {
                return anchor
            }
        }
        guard selection.side == .new, let fileLines,
              fileLines.indices.contains(selection.start - 1) else {
            return nil
        }
        return .make(line: selection.start, span: selection.span, in: fileLines)
    }

    /// The single line case, which is what the gutter `+` pressed without a drag asks for.
    public static func anchor(
        at spot: ReviewSpot,
        hunks: [DiffHunk],
        fileLines: [String]?
    ) -> ReviewCommentAnchor? {
        anchor(at: ReviewSelection(spot), hunks: hunks, fileLines: fileLines)
    }
}

// MARK: - Placement

/// Where one pending comment should be drawn in the diff that is on screen now, decided honestly.
///
/// The line number a comment was written against stops being true the moment the agent edits the
/// file, and the diff view refreshes underneath pending comments every few seconds. Drawing the
/// band at the stored number regardless would pin a remark about one line under whatever line
/// wears that number now, which is worse than drawing no band at all: the reviewer would read
/// their own comment as being about code it is not about. So every comment is re-checked against
/// the diff being drawn, and one that cannot be verified says so instead of guessing.
public struct ReviewPlacement: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        /// The anchored text is on this printed line. `moved` says the number changed since the
        /// comment was written, which the band tells the reviewer rather than leaving them to
        /// notice.
        case placed(ReviewSpot, moved: Bool)
        /// The line still exists in the file, at this number, but the diff on screen does not
        /// print it (it sits in a collapsed context gap). The band would have nothing to sit
        /// under, so the comment is listed at the top of the diff instead.
        case hidden(line: Int)
        /// The line is gone, was rewritten, or (for the old side) cannot be re-checked because
        /// the old text no longer appears in the diff. The payload falls back to the snapshot
        /// stored on the anchor, and the view says the line is gone rather than pointing at a
        /// wrong one.
        case outdated
    }

    public var comment: ReviewComment
    public var status: Status
    /// Every line of the note that the diff on screen actually prints, in file order.
    ///
    /// One entry for a note left on a single line, which is what it was before dragging across
    /// the gutter existed, and up to `span` for a note left across several. It is what the diff
    /// tints and it is where the band goes, and it holds only PRINTED lines on purpose: a range
    /// whose tail runs past the end of the hunk on screen would otherwise put its band under a
    /// line nobody can see, which is the same vanishing act `ReviewPlacements` exists to prevent
    /// for the head of it.
    public var covered: [ReviewSpot]

    public var id: ReviewCommentID { comment.id }

    /// Where the note anchors, which is its first line. Nil when the diff cannot place it.
    public var spot: ReviewSpot? {
        if case .placed(let spot, _) = status { return spot }
        return nil
    }

    /// The printed line the band sits under: the LAST line the note covers, so a range reads as
    /// being about the lines above it rather than as covering them. A single line note is its own
    /// last line, so nothing about the old behaviour moves.
    public var band: ReviewSpot? { covered.last ?? spot }

    /// - Parameter covered: the printed lines, when the caller has worked them out against the
    ///   diff being drawn. The default is the anchor line alone, which is the whole of a
    ///   single line note and is what every caller outside `ReviewPlacements.place` wants.
    public init(comment: ReviewComment, status: Status, covered: [ReviewSpot]? = nil) {
        self.comment = comment
        self.status = status
        if let covered {
            self.covered = covered
        } else if case .placed(let spot, _) = status {
            self.covered = [spot]
        } else {
            self.covered = []
        }
    }
}

public enum ReviewPlacements {
    /// Decide where every comment on one file draws, against the diff being rendered.
    ///
    /// `currentLines` is the worktree copy of the file, which is what a moved new-side line is
    /// re-found in; nil means the file could not be read, and an unverifiable comment reports
    /// itself outdated rather than exact. `revealedNewLines` are the between-hunk context lines
    /// the reader has expanded, keyed by new-side number: they are printed and can carry a band,
    /// and the hunks know nothing about them.
    public static func place(
        _ comments: [ReviewComment],
        in file: FileDiff,
        currentLines: [String]?,
        revealedNewLines: [Int: String] = [:]
    ) -> [ReviewPlacement] {
        var oldLines: [Int: String] = [:]
        var newLines: [Int: String] = revealedNewLines
        for hunk in file.hunks {
            for line in hunk.lines where line.kind != .noNewline {
                if let number = line.oldNumber { oldLines[number] = line.text }
                if let number = line.newNumber { newLines[number] = line.text }
            }
        }

        return comments.sortedForReview().map { comment in
            let printed = comment.side == .old ? oldLines : newLines

            // The worktree outranks the diff for a new-side comment, deliberately. The two can
            // briefly disagree (the diff on screen is a snapshot, the file is live), and the
            // payload the agent gets resolves against the worktree, so a band placed off the diff
            // alone could sit under a line the payload was about to call gone. That disagreement
            // is the exact failure `ReviewCommentRender`'s comment warns against.
            if comment.side == .new, let currentLines {
                let resolution = comment.anchor.resolve(in: currentLines)
                guard !resolution.isOutdated else {
                    return ReviewPlacement(comment: comment, status: .outdated)
                }
                if printed[resolution.line] == comment.anchor.text {
                    return ReviewPlacement(
                        comment: comment,
                        status: .placed(
                            ReviewSpot(side: .new, line: resolution.line),
                            moved: resolution.line != comment.anchor.line
                        ),
                        covered: covered(
                            from: resolution.line, span: comment.anchor.span,
                            side: .new, printed: printed
                        )
                    )
                }
                return ReviewPlacement(comment: comment, status: .hidden(line: resolution.line))
            }

            // The old side, and a new side whose file could not be read. Only the diff's own
            // printed text can vouch for these: the old side of the diff is the merge base's
            // copy, and the whole reason the comment kept a snapshot is that the old blob is not
            // in hand here. A line the diff no longer prints at its number is reported outdated,
            // and the payload's own resolver says the same when the message goes.
            if printed[comment.anchor.line] == comment.anchor.text {
                return ReviewPlacement(
                    comment: comment,
                    status: .placed(
                        ReviewSpot(side: comment.side, line: comment.anchor.line), moved: false
                    ),
                    covered: covered(
                        from: comment.anchor.line, span: comment.anchor.span,
                        side: comment.side, printed: printed
                    )
                )
            }
            return ReviewPlacement(comment: comment, status: .outdated)
        }
    }

    /// The lines of one note that the diff prints, from its resolved first line onwards.
    ///
    /// It stops at the first line the diff does not print rather than skipping over it, because
    /// the run has to be the lines the band is drawn beneath: a note covering 10 to 14 where 12
    /// is inside a collapsed gap is a note about a stretch of file the reader is only shown part
    /// of, and tinting 13 and 14 with a hole in the middle would say the note is about two
    /// separate places. The first line is always in, because the caller has already matched its
    /// text against the diff.
    private static func covered(
        from line: Int,
        span: Int,
        side: ReviewCommentSide,
        printed: [Int: String]
    ) -> [ReviewSpot] {
        var spots = [ReviewSpot(side: side, line: line)]
        guard span > 1 else { return spots }
        for number in (line + 1)..<(line + span) {
            guard printed[number] != nil else { break }
            spots.append(ReviewSpot(side: side, line: number))
        }
        return spots
    }
}
