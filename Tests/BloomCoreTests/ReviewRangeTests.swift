import Testing
import Foundation
@testable import BloomCore

/// A note left by dragging down the gutter covers several lines, and every part of the review has
/// to agree about which ones: the anchor that stores it, the diff that draws it, the payload the
/// agent reads, and the reader that turns a sent turn back into chips.
@Suite("Review comment ranges")
struct ReviewRangeTests {
    // MARK: - The selection a drag makes

    @Test("a selection normalises whichever way it was dragged")
    func normalises() {
        let down = ReviewSelection(side: .new, start: 4, end: 8)
        let up = ReviewSelection(side: .new, start: 8, end: 4)

        #expect(down == up)
        #expect(up.start == 4)
        #expect(up.end == 8)
        #expect(up.span == 5)
        #expect(up.isRange)
        #expect(up.anchor == ReviewSpot(side: .new, line: 4))
        #expect(up.spots.map(\.line) == [4, 5, 6, 7, 8])
    }

    @Test("a selection is one side or nothing")
    func refusesCrossingSides() throws {
        let from = ReviewSpot(side: .new, line: 2)
        let same = try #require(ReviewSelection(from: from, to: ReviewSpot(side: .new, line: 5)))
        #expect(same.span == 4)

        // The old side is the merge base's copy and the new side is the worktree's, so a range
        // across the two is a range over two different files.
        #expect(ReviewSelection(from: from, to: ReviewSpot(side: .old, line: 5)) == nil)
    }

    @Test("one spot is a selection of one line")
    func singleSpot() {
        let selection = ReviewSelection(ReviewSpot(side: .old, line: 12))

        #expect(selection.span == 1)
        #expect(!selection.isRange)
        #expect(selection.contains(ReviewSpot(side: .old, line: 12)))
        #expect(!selection.contains(ReviewSpot(side: .new, line: 12)))
    }

    // MARK: - What the anchor keeps

    @Test("an anchor keeps the first line, its neighbours, and how many lines it covers")
    func capturesSpan() {
        let lines = (1...20).map { "line \($0)" }
        let anchor = ReviewCommentAnchor.make(line: 10, span: 4, in: lines)

        #expect(anchor.line == 10)
        #expect(anchor.text == "line 10")
        #expect(anchor.span == 4)
        #expect(anchor.lastLine == 13)
        #expect(anchor.isRange)
        // The neighbours are still the anchor's own, three each way, whatever the span: the range
        // itself is re-read out of the file, and only the first line has to be re-found.
        #expect(anchor.before == ["line 7", "line 8", "line 9"])
        #expect(anchor.after == ["line 11", "line 12", "line 13"])
    }

    @Test("a span below one is one line")
    func floorsSpan() {
        #expect(ReviewCommentAnchor(line: 3, text: "x", span: 0).span == 1)
        #expect(ReviewCommentAnchor(line: 3, text: "x", span: -4).lastLine == 3)
    }

    @Test("a range anchored in a hunk is captured off the diff's own lines")
    func capturesFromHunk() throws {
        let file = try #require(DiffParser.parse(ReviewPlacementTests.patch).first)
        let selection = ReviewSelection(side: .new, start: 2, end: 4)
        let anchor = try #require(ReviewCapture.anchor(
            at: selection, hunks: file.hunks, fileLines: nil
        ))

        #expect(anchor.line == 2)
        #expect(anchor.span == 3)
        #expect(anchor.text == "TWO")
    }

    @Test("the resolver re-finds a range by its first line and the rest slides with it")
    func resolvesByFirstLine() {
        let anchor = ReviewCommentAnchor.make(
            line: 3, span: 3, in: ["a", "b", "c", "d", "e", "f"]
        )
        // Two lines inserted above, so the note is now on 5 to 7 without anything about it
        // having been rewritten.
        let moved = ["x", "y", "a", "b", "c", "d", "e", "f"]
        let resolution = anchor.resolve(in: moved)

        #expect(resolution.status == .shifted)
        #expect(resolution.line == 5)
        #expect(anchor.span == 3)
    }

    // MARK: - Where the diff draws it

    @Test("a range tints every line it covers and the band sits under the last of them")
    func placesUnderTheLastLine() throws {
        let file = try #require(DiffParser.parse(ReviewPlacementTests.patch).first)
        let comment = ReviewComment(
            workspaceID: WorkspaceID("w"),
            filePath: "Widget.swift",
            anchor: ReviewCommentAnchor(line: 2, text: "TWO", span: 3),
            body: "these three belong together"
        )

        let placement = try #require(ReviewPlacements.place(
            [comment], in: file, currentLines: ReviewPlacementTests.current
        ).first)

        #expect(placement.status == .placed(ReviewSpot(side: .new, line: 2), moved: false))
        #expect(placement.spot == ReviewSpot(side: .new, line: 2))
        #expect(placement.covered.map(\.line) == [2, 3, 4])
        #expect(placement.band == ReviewSpot(side: .new, line: 4))
    }

    @Test("a range stops at the first line the diff does not print")
    func stopsAtTheEdgeOfTheDiff() throws {
        let file = try #require(DiffParser.parse(ReviewPlacementTests.patch).first)
        // The patch prints four lines; this note claims to cover six, which is what a diff
        // refolded under a pending comment leaves behind.
        let comment = ReviewComment(
            workspaceID: WorkspaceID("w"),
            filePath: "Widget.swift",
            anchor: ReviewCommentAnchor(line: 3, text: "three", span: 6),
            body: "the tail is off the screen"
        )

        let placement = try #require(ReviewPlacements.place(
            [comment], in: file, currentLines: ReviewPlacementTests.current + ["five", "six"]
        ).first)

        #expect(placement.covered.map(\.line) == [3, 4])
        #expect(placement.band == ReviewSpot(side: .new, line: 4))
    }

    @Test("a single line note places exactly as it always did")
    func singleLineIsUnchanged() throws {
        let file = try #require(DiffParser.parse(ReviewPlacementTests.patch).first)
        let comment = ReviewComment(
            workspaceID: WorkspaceID("w"),
            filePath: "Widget.swift",
            anchor: ReviewCommentAnchor(line: 2, text: "TWO"),
            body: "note"
        )

        let placement = try #require(ReviewPlacements.place(
            [comment], in: file, currentLines: ReviewPlacementTests.current
        ).first)

        #expect(placement.covered == [ReviewSpot(side: .new, line: 2)])
        #expect(placement.band == placement.spot)
    }

    // MARK: - What the agent is handed

    private func rangeComment(span: Int) -> ReviewComment {
        ReviewComment(
            id: ReviewCommentID("c1"),
            workspaceID: WorkspaceID("w"),
            filePath: "Widget.swift",
            anchor: ReviewCommentAnchor.make(
                line: 3, span: span, in: ReviewRangeTests.file
            ),
            body: "pull these out into one function"
        )
    }

    static let file = [
        "import Foundation",
        "",
        "func first() {}",
        "func second() {}",
        "func third() {}",
        "",
        "let done = true",
    ]

    @Test("the payload names both ends and marks every line of the range")
    func rendersTheRange() {
        let text = ReviewPayload.text(
            for: [rangeComment(span: 3)], currentLines: { _ in ReviewRangeTests.file }
        )

        #expect(text.contains("### Lines 3 to 5"))
        // Every line of the range is marked, and only those.
        #expect(text.contains("> 3 | func first() {}"))
        #expect(text.contains("> 4 | func second() {}"))
        #expect(text.contains("> 5 | func third() {}"))
        #expect(text.contains("  2 |"))
        #expect(text.contains("  6 |"))
    }

    @Test("a single line note is still written the way it always was")
    func rendersOneLine() {
        let text = ReviewPayload.text(
            for: [rangeComment(span: 1)], currentLines: { _ in ReviewRangeTests.file }
        )

        #expect(text.contains("### Line 3"))
        #expect(!text.contains("Lines"))
    }

    @Test("a moved range says so in the plural")
    func speaksInThePlural() {
        // The same file with two lines put in above it, so the note has slid down.
        let moved = ["// one", "// two"] + ReviewRangeTests.file
        let text = ReviewPayload.text(
            for: [rangeComment(span: 3)], currentLines: { _ in moved }
        )

        #expect(text.contains("### Lines 5 to 7"))
        #expect(text.contains("these lines have moved"))
        #expect(text.contains("they were lines 3 to 5"))
    }

    @Test("a range whose file is gone falls back to the snapshot it kept")
    func fallsBackToTheSnapshot() {
        let text = ReviewPayload.text(for: [rangeComment(span: 3)], currentLines: { _ in nil })

        #expect(text.contains("could not be read"))
        // The snapshot holds the anchor and three lines after it, so both of the other lines in
        // the range are marked and the line past it is not.
        #expect(text.contains("> 3 | func first() {}"))
        #expect(text.contains("> 5 | func third() {}"))
        #expect(text.contains("  6 |"))
    }

    // MARK: - Reading a sent turn back

    @Test("a sent range comes back as one chip that knows both ends")
    func readsBackARange() throws {
        let sent = ReviewTurn.compose(
            message: "have a look",
            comments: [rangeComment(span: 3)],
            worktreePath: nil,
            template: PromptRegistry.definition(for: .review).defaultTemplate
        )

        let record = try #require(ReviewTurn.split(sent))
        let chip = try #require(record.chips.first)

        #expect(record.message == "have a look")
        #expect(record.chips.count == 1)
        #expect(chip.line == 3)
        #expect(chip.lastLine == 5)
        #expect(chip.lineDescription == "lines 3 to 5")
        #expect(chip.body == "pull these out into one function")
    }

    @Test("a sent single line still reads back as a single line")
    func readsBackOneLine() throws {
        let sent = ReviewTurn.compose(
            message: "",
            comments: [rangeComment(span: 1)],
            worktreePath: nil,
            template: PromptRegistry.definition(for: .review).defaultTemplate
        )

        let chip = try #require(ReviewTurn.split(sent)?.chips.first)

        #expect(chip.line == 3)
        #expect(chip.lastLine == 3)
        #expect(chip.lineDescription == "line 3")
    }

    // MARK: - What a chip says

    @Test("a chip spells out both ends of a range and one number otherwise")
    func labelsARange() {
        let one = ReviewComment(
            workspaceID: WorkspaceID("w"), filePath: "a/Widget.swift",
            anchor: ReviewCommentAnchor(line: 34, text: "x"), body: "b"
        )
        let range = ReviewComment(
            workspaceID: WorkspaceID("w"), filePath: "a/Widget.swift",
            anchor: ReviewCommentAnchor(line: 34, text: "x", span: 5), body: "b"
        )
        let removed = ReviewComment(
            workspaceID: WorkspaceID("w"), filePath: "a/Widget.swift", side: .old,
            anchor: ReviewCommentAnchor(line: 34, text: "x", span: 5), body: "b"
        )

        #expect(ReviewCommentSummary.chip(for: one) == "Widget.swift +34")
        #expect(ReviewCommentSummary.chip(for: range) == "Widget.swift +34…38")
        // The sign is written once, so the old side does not come out as arithmetic.
        #expect(ReviewCommentSummary.chip(for: removed) == "Widget.swift -34…38")
        #expect(ReviewCommentSummary.label(for: [one, range]) == "Widget.swift +34 +34…38")
    }
}

/// Where a drag down the gutter has got to, which is arithmetic on a row height because most rows
/// of a diff are drawn as one text object with no per line view to hit test.
@Suite("Diff drag range")
struct DiffDragRangeTests {
    private static let rowHeight: CGFloat = 18

    @Test("a drag moves a row at a time, rounding at the halfway mark")
    func countsRows() {
        #expect(DiffDragRange.row(from: 2, translation: 0, rowHeight: Self.rowHeight, count: 10) == 2)
        #expect(DiffDragRange.row(from: 2, translation: 8, rowHeight: Self.rowHeight, count: 10) == 2)
        #expect(DiffDragRange.row(from: 2, translation: 10, rowHeight: Self.rowHeight, count: 10) == 3)
        #expect(DiffDragRange.row(from: 2, translation: 54, rowHeight: Self.rowHeight, count: 10) == 5)
        #expect(DiffDragRange.row(from: 2, translation: -36, rowHeight: Self.rowHeight, count: 10) == 0)
    }

    @Test("wrapped rows retain their source line for hover and drag")
    func wrappedRows() {
        let heights: [CGFloat] = [18, 72, 18]
        #expect(DiffDragRange.row(at: 17, heights: heights) == 0)
        #expect(DiffDragRange.row(at: 18, heights: heights) == 1)
        #expect(DiffDragRange.row(at: 89, heights: heights) == 1)
        #expect(DiffDragRange.row(at: 90, heights: heights) == 2)
        #expect(DiffDragRange.row(at: 108, heights: heights) == nil)
        #expect(DiffDragRange.row(at: -1, heights: heights) == nil)
        let spots = (1...3).map { Optional(ReviewSpot(side: .new, line: $0)) }
        #expect(DiffDragRange.spot(from: 0, translation: 70, rowHeight: 18,
                                  rowHeights: heights, spots: spots, side: .new)?.line == 2)
        #expect(DiffDragRange.spot(from: 0, translation: 82, rowHeight: 18,
                                  rowHeights: heights, spots: spots, side: .new)?.line == 3)
        #expect(DiffDragRange.spot(from: 2, translation: -25, rowHeight: 18,
                                  rowHeights: heights, spots: spots, side: .new)?.line == 2)
    }

    @Test("a drag is clamped to the block it began in")
    func clamps() {
        #expect(DiffDragRange.row(from: 1, translation: 900, rowHeight: Self.rowHeight, count: 4) == 3)
        #expect(DiffDragRange.row(from: 1, translation: -900, rowHeight: Self.rowHeight, count: 4) == 0)
        // A block with nothing in it and a row height of nought are both callers' mistakes rather
        // than states to support, and neither may trap: a diff that draws is worth more.
        #expect(DiffDragRange.row(from: 3, translation: 40, rowHeight: Self.rowHeight, count: 0) == 0)
        #expect(DiffDragRange.row(from: 3, translation: 40, rowHeight: 0, count: 6) == 3)
    }

    /// A unified hunk: two added lines, a deletion between them, then two more added lines.
    private static let spots: [ReviewSpot?] = [
        ReviewSpot(side: .new, line: 10),
        ReviewSpot(side: .old, line: 12),
        ReviewSpot(side: .new, line: 11),
        nil,
        ReviewSpot(side: .new, line: 12),
    ]

    @Test("a drag steps over a row belonging to the other side")
    func stepsOverTheOtherSide() {
        let target = DiffDragRange.spot(
            from: 0, translation: Self.rowHeight * 2,
            rowHeight: Self.rowHeight, spots: Self.spots, side: .new
        )

        #expect(target == ReviewSpot(side: .new, line: 11))
    }

    @Test("a drag landing on a row that offers nothing falls back to the last one that did")
    func stepsBack() {
        // Row 3 is the padding opposite a longer run, so the range ends on row 2.
        let target = DiffDragRange.spot(
            from: 0, translation: Self.rowHeight * 3,
            rowHeight: Self.rowHeight, spots: Self.spots, side: .new
        )

        #expect(target == ReviewSpot(side: .new, line: 11))
    }

    @Test("a drag that finds nothing on its own side collapses back to where it began")
    func collapsesToTheStart() {
        let target = DiffDragRange.spot(
            from: 1, translation: -Self.rowHeight,
            rowHeight: Self.rowHeight, spots: Self.spots, side: .old
        )

        // Upwards from the deletion there is only a new-side line, and a range never crosses the
        // sides, so the walk back reaches the row the drag began on and stops there: the
        // selection stays the one line it started as rather than jumping to the other version of
        // the file.
        #expect(target == ReviewSpot(side: .old, line: 12))
    }

    @Test("a drag out of a block that offers nothing at all answers with nothing")
    func refusesWhenNothingMatches() {
        let target = DiffDragRange.spot(
            from: 0, translation: Self.rowHeight,
            rowHeight: Self.rowHeight, spots: [nil, nil], side: .new
        )

        #expect(target == nil)
    }
}
