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
        at spot: ReviewSpot,
        hunks: [DiffHunk],
        fileLines: [String]?
    ) -> ReviewCommentAnchor? {
        for hunk in hunks {
            if let anchor = ReviewCommentAnchor.make(line: spot.line, side: spot.side, in: hunk) {
                return anchor
            }
        }
        guard spot.side == .new, let fileLines, fileLines.indices.contains(spot.line - 1) else {
            return nil
        }
        return .make(line: spot.line, in: fileLines)
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

    public var id: ReviewCommentID { comment.id }

    /// The printed line the band sits under, when there is one.
    public var spot: ReviewSpot? {
        if case .placed(let spot, _) = status { return spot }
        return nil
    }

    public init(comment: ReviewComment, status: Status) {
        self.comment = comment
        self.status = status
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
                    )
                )
            }
            return ReviewPlacement(comment: comment, status: .outdated)
        }
    }
}
