import Testing
import Foundation
@testable import BloomCore

/// Placement is what keeps the comment bands honest while the agent edits underneath them: a
/// band is only ever drawn under a printed line whose text is still the text the comment was
/// written against, and everything else says what happened instead of guessing.
@Suite("Review placement")
struct ReviewPlacementTests {
    static let patch = """
    diff --git a/Widget.swift b/Widget.swift
    --- a/Widget.swift
    +++ b/Widget.swift
    @@ -1,4 +1,4 @@
     one
    -two
    +TWO
     three
     four
    """

    private func file() throws -> FileDiff {
        try #require(DiffParser.parse(Self.patch).first)
    }

    /// The new side of the patch above, which is what the worktree holds when nothing moved.
    static let current = ["one", "TWO", "three", "four"]

    private func comment(
        line: Int,
        text: String,
        side: ReviewCommentSide = .new,
        before: [String] = [],
        after: [String] = []
    ) -> ReviewComment {
        ReviewComment(
            id: ReviewCommentID("c\(line)\(side.rawValue)"),
            workspaceID: WorkspaceID("w"),
            filePath: "Widget.swift",
            side: side,
            anchor: ReviewCommentAnchor(line: line, text: text, before: before, after: after),
            body: "note"
        )
    }

    @Test("a comment whose line is unchanged sits at home")
    func placesExactly() throws {
        let placed = ReviewPlacements.place(
            [comment(line: 2, text: "TWO")], in: try file(), currentLines: Self.current
        )

        #expect(placed.first?.status == .placed(ReviewSpot(side: .new, line: 2), moved: false))
    }

    @Test("an old-side comment sits on the deletion that carries its text")
    func placesOldSide() throws {
        let placed = ReviewPlacements.place(
            [comment(line: 2, text: "two", side: .old)], in: try file(), currentLines: Self.current
        )

        #expect(placed.first?.status == .placed(ReviewSpot(side: .old, line: 2), moved: false))
    }

    @Test("a line that moved is re-found and says so")
    func followsAMovedLine() throws {
        // The agent inserted a line above, so everything below slid down one. The diff being
        // rendered has followed: TWO is printed at new line 3 now.
        let patch = """
        diff --git a/Widget.swift b/Widget.swift
        --- a/Widget.swift
        +++ b/Widget.swift
        @@ -1,4 +1,5 @@
         one
        +zero
        -two
        +TWO
         three
        """
        let moved = try #require(DiffParser.parse(patch).first)
        let placed = ReviewPlacements.place(
            [comment(line: 2, text: "TWO", before: ["one"], after: ["three"])],
            in: moved,
            currentLines: ["one", "zero", "TWO", "three", "four"]
        )

        #expect(placed.first?.status == .placed(ReviewSpot(side: .new, line: 3), moved: true))
    }

    @Test("a rewritten line is reported outdated rather than pinned to a stranger")
    func reportsARewrittenLine() throws {
        let placed = ReviewPlacements.place(
            [comment(line: 2, text: "TWO")],
            in: try file(),
            currentLines: ["one", "SOMETHING ELSE", "three", "four"]
        )

        #expect(placed.first?.status == .outdated)
    }

    @Test("a line alive in the file but not printed by the diff is hidden, not outdated")
    func reportsAHiddenLine() throws {
        // The comment is on "four", which the worktree still holds, but the diff being drawn
        // stops printing at "three".
        let patch = """
        diff --git a/Widget.swift b/Widget.swift
        --- a/Widget.swift
        +++ b/Widget.swift
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        """
        let short = try #require(DiffParser.parse(patch).first)
        let placed = ReviewPlacements.place(
            [comment(line: 4, text: "four")], in: short, currentLines: Self.current
        )

        #expect(placed.first?.status == .hidden(line: 4))
    }

    @Test("a revealed between-hunks line can carry a band")
    func honoursRevealedLines() throws {
        let patch = """
        diff --git a/Widget.swift b/Widget.swift
        --- a/Widget.swift
        +++ b/Widget.swift
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        """
        let short = try #require(DiffParser.parse(patch).first)
        let placed = ReviewPlacements.place(
            [comment(line: 4, text: "four")],
            in: short,
            currentLines: Self.current,
            revealedNewLines: [4: "four"]
        )

        #expect(placed.first?.status == .placed(ReviewSpot(side: .new, line: 4), moved: false))
    }

    @Test("an unreadable file leaves an unmatched comment outdated rather than guessed")
    func handlesAnUnreadableFile() throws {
        let placed = ReviewPlacements.place(
            [comment(line: 9, text: "nowhere")], in: try file(), currentLines: nil
        )

        #expect(placed.first?.status == .outdated)
    }

    @Test("an old-side comment whose deletion left the diff is outdated")
    func oldSideCannotBeReFound() throws {
        let placed = ReviewPlacements.place(
            [comment(line: 9, text: "gone", side: .old)], in: try file(), currentLines: Self.current
        )

        #expect(placed.first?.status == .outdated)
    }

    @Test("placements keep review order")
    func keepsOrder() throws {
        let placed = ReviewPlacements.place(
            [comment(line: 3, text: "three"), comment(line: 1, text: "one")],
            in: try file(),
            currentLines: Self.current
        )

        #expect(placed.map(\.comment.anchor.line) == [1, 3])
    }
}

/// Which side a rendered line offers for commenting.
@Suite("Review spot")
struct ReviewSpotTests {
    @Test("a deletion is addressed on the old side, everything else on the new")
    func sides() {
        let deletion = DiffLine(kind: .deletion, text: "two", oldNumber: 2, newNumber: nil, index: 0)
        let addition = DiffLine(kind: .addition, text: "TWO", oldNumber: nil, newNumber: 2, index: 1)
        let context = DiffLine(kind: .context, text: "one", oldNumber: 1, newNumber: 1, index: 2)
        let marker = DiffLine(kind: .noNewline, text: "", oldNumber: nil, newNumber: nil, index: 3)

        #expect(deletion.reviewSpot == ReviewSpot(side: .old, line: 2))
        #expect(addition.reviewSpot == ReviewSpot(side: .new, line: 2))
        #expect(context.reviewSpot == ReviewSpot(side: .new, line: 1))
        #expect(marker.reviewSpot == nil)
    }

    @Test("capture falls back to the worktree copy for a revealed context line")
    func captureFallsBack() throws {
        let file = try #require(DiffParser.parse(ReviewPlacementTests.patch).first)

        // Line 2 is printed by the hunk, so it is captured with the diff's own neighbours.
        let printed = try #require(ReviewCapture.anchor(
            at: ReviewSpot(side: .new, line: 2), hunks: file.hunks, fileLines: nil
        ))
        #expect(printed.text == "TWO")

        // Line 40 is not in any hunk; only the worktree copy can anchor it.
        let lines = (1...50).map { "line \($0)" }
        let revealed = try #require(ReviewCapture.anchor(
            at: ReviewSpot(side: .new, line: 40), hunks: file.hunks, fileLines: lines
        ))
        #expect(revealed.text == "line 40")

        // An old-side line no hunk printed was never on screen, so there is nothing to anchor.
        #expect(ReviewCapture.anchor(
            at: ReviewSpot(side: .old, line: 40), hunks: file.hunks, fileLines: lines
        ) == nil)
    }
}
