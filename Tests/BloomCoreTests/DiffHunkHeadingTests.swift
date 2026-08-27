import Testing
@testable import BloomCore

/// The report: a grey band reading `{} public function __construct(` between line 48 and line 49,
/// numbering contiguous either side of it. `DiffView` drew one for every hunk, so a reader who had
/// expanded the gap above a hunk got a band naming the scope they were already sitting in.
@Suite("Hunk headings")
struct DiffHunkHeadingTests {
    private func hunk(newStart: Int, newCount: Int, header: String = " func work()") -> DiffHunk {
        DiffHunk(
            oldStart: newStart, oldCount: newCount,
            newStart: newStart, newCount: newCount,
            header: header, lines: []
        )
    }

    /// The case the band exists for: lines were skipped, so the reader needs telling where they
    /// have landed.
    @Test("a hunk reached over skipped lines gets a band")
    func skippedLinesEarnABand() {
        let hunks = [hunk(newStart: 1, newCount: 5), hunk(newStart: 40, newCount: 6)]
        #expect(DiffHunkHeading.text(for: hunks, at: 1, revealed: 0) == "func work()")
    }

    /// The first hunk is the same question asked of the head of the file: everything above it is
    /// skipped, and there is nothing above it to skip.
    @Test("the first hunk is judged against the top of the file")
    func theFirstHunkIsJudgedAgainstLineOne() {
        #expect(DiffHunkHeading.text(for: [hunk(newStart: 48, newCount: 6)], at: 0, revealed: 0)
            == "func work()")
        #expect(DiffHunkHeading.text(for: [hunk(newStart: 1, newCount: 6)], at: 0, revealed: 0)
            == nil)
    }

    /// The report, reproduced. The gap is revealed upward from the hunk, so its last revealed
    /// line is always the one directly above the band, and once every line of it is up the
    /// numbering runs straight through.
    @Test("a fully revealed gap takes the band with it")
    func aRevealedGapLosesItsBand() {
        let hunks = [hunk(newStart: 1, newCount: 5), hunk(newStart: 49, newCount: 6)]
        // 6..<49 is the gap, so 43 lines of it.
        #expect(DiffHunkHeading.text(for: hunks, at: 1, revealed: 42) != nil)
        #expect(DiffHunkHeading.text(for: hunks, at: 1, revealed: 43) == nil)
        #expect(DiffHunkHeading.text(for: hunks, at: 1, revealed: 500) == nil)
    }

    /// Git does not emit touching hunks at three lines of context, so this is arithmetic the pane
    /// should never see. It is stated anyway, because the rule must not depend on that being true.
    @Test("touching hunks get nothing")
    func touchingHunksGetNothing() {
        let hunks = [hunk(newStart: 1, newCount: 9), hunk(newStart: 10, newCount: 3)]
        #expect(DiffHunkHeading.text(for: hunks, at: 1, revealed: 0) == nil)
    }

    /// A scope that changed is not a case of its own: it can only show up once the gap is fully
    /// revealed, and the revealed lines include the very line the band would have quoted.
    @Test("a changed scope over contiguous lines still gets nothing")
    func aChangedScopeOverContiguousLinesGetsNothing() {
        let hunks = [
            hunk(newStart: 1, newCount: 5, header: " func one()"),
            hunk(newStart: 40, newCount: 6, header: " func two()"),
        ]
        #expect(DiffHunkHeading.text(for: hunks, at: 1, revealed: 34) == nil)
    }

    /// Git leaves the name off every hunk it cannot find a scope for, and the band was never
    /// empty: it fell back to the coordinates. Kept, because with an unreadable worktree copy
    /// there is no expander either and the band is the only mark of the jump.
    @Test("an unnamed hunk falls back to its coordinates")
    func anUnnamedHunkFallsBackToCoordinates() {
        let hunks = [hunk(newStart: 1, newCount: 5, header: ""), hunk(newStart: 40, newCount: 6, header: "")]
        #expect(DiffHunkHeading.text(for: hunks, at: 1, revealed: 0) == "@@ -40,6 +40,6 @@")
    }

    @Test("an index no hunk has gets nothing")
    func anIndexNoHunkHasGetsNothing() {
        #expect(DiffHunkHeading.text(for: [], at: 0, revealed: 0) == nil)
        #expect(DiffHunkHeading.text(for: [hunk(newStart: 40, newCount: 6)], at: 3, revealed: 0)
            == nil)
        #expect(DiffHunkHeading.text(for: [hunk(newStart: 40, newCount: 6)], at: -1, revealed: 0)
            == nil)
    }

    /// The header text is what the parser kept, with git's leading space taken off.
    @Test("the band shows the scope git named")
    func theBandShowsTheScopeGitNamed() {
        #expect(DiffHunkHeading.text(of: hunk(newStart: 9, newCount: 2, header: " class A {"))
            == "class A {")
    }
}
