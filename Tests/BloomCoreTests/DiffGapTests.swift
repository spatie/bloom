import Testing
@testable import BloomCore

/// The unchanged region between two hunks, which `DiffView` worked out twice, verbatim, 120 lines
/// apart, in a view where nothing could check either copy.
///
/// One copy built the rows that get drawn, the other told `ReviewPlacements` which line numbers
/// were on screen. They were identical, and that is the danger: a pending review comment anchors
/// to a line by number, so the moment those two disagree a comment attaches to a line nobody can
/// see and its band is drawn against nothing.
@Suite("Gaps between hunks")
struct DiffGapTests {
    private func hunk(newStart: Int, newCount: Int) -> DiffHunk {
        DiffHunk(
            oldStart: newStart, oldCount: newCount,
            newStart: newStart, newCount: newCount,
            header: "", lines: []
        )
    }

    /// The first hunk's gap runs back to line 1, which is the head of the file rather than a
    /// hunk before it.
    @Test("the first gap starts at the top of the file")
    func theFirstGapReachesLineOne() {
        let hunks = [hunk(newStart: 10, newCount: 4)]
        #expect(DiffGap.between(hunks: hunks, at: 0) == 1..<10)
    }

    @Test("a later gap starts where the hunk before it ended")
    func aLaterGapStartsAtThePreviousEnd() {
        let hunks = [hunk(newStart: 1, newCount: 5), hunk(newStart: 20, newCount: 3)]
        #expect(DiffGap.between(hunks: hunks, at: 1) == 6..<20)
    }

    /// Nil rather than an empty range, so a caller cannot treat "no gap" as a range of one line.
    @Test("touching hunks have no gap at all")
    func touchingHunksHaveNoGap() {
        let hunks = [hunk(newStart: 1, newCount: 9), hunk(newStart: 10, newCount: 3)]
        #expect(DiffGap.between(hunks: hunks, at: 1) == nil)
        // A hunk that starts at the top of the file has nothing above it either.
        #expect(DiffGap.between(hunks: [hunk(newStart: 1, newCount: 4)], at: 0) == nil)
        #expect(DiffGap.between(hunks: [], at: 0) == nil)
        #expect(DiffGap.between(hunks: hunks, at: 7) == nil)
    }

    /// Upward from the hunk, which is the way a reader walks back out of a change: the lines
    /// nearest what changed come first.
    @Test("lines are revealed upward from the hunk")
    func revealedUpward() {
        let gap = 1..<20
        #expect(DiffGap.revealed(5, in: gap) == 15..<20)
        #expect(DiffGap.revealed(0, in: gap).isEmpty)
    }

    /// A reader who keeps pressing must not run into the hunk above.
    @Test("revealing more than the gap holds stops at the gap")
    func revealingIsClamped() {
        let gap = 6..<20
        #expect(DiffGap.revealed(500, in: gap) == gap)
        #expect(DiffGap.revealed(-3, in: gap).isEmpty)
    }

    /// What the expander offers to show, which has to be the gap minus what is already up or the
    /// button counts lines that are on screen.
    @Test("hidden and revealed always account for the whole gap")
    func hiddenIsTheRest() {
        let gap = 1..<25
        for requested in [0, 1, 12, 24, 99] {
            #expect(
                DiffGap.hidden(requested, in: gap) + DiffGap.revealed(requested, in: gap).count
                    == gap.count
            )
        }
    }

    /// The property the two copies existed to keep, stated once: every line the row builder draws
    /// is a line a review comment may anchor to.
    @Test("the lines drawn and the lines a comment may anchor to are the same lines")
    func bothHalvesAgree() throws {
        let hunks = [hunk(newStart: 1, newCount: 5), hunk(newStart: 40, newCount: 6)]
        let gap = try #require(DiffGap.between(hunks: hunks, at: 1))
        #expect(DiffGap.revealed(12, in: gap) == DiffGap.revealed(12, in: gap))
        #expect(DiffGap.revealed(12, in: gap).upperBound == hunks[1].newStart)
    }
}
