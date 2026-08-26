import Testing
import Foundation
@testable import BloomCore

@Suite("Remembering how tall a transcript row is")
struct TranscriptRowHeightsTests {
    // MARK: - What the cache is keyed on

    @Test("a row measured once is not measured again")
    func remembersAHeight() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7|assistant")
        #expect(heights.height(for: "row.7|assistant") == 120)
    }

    @Test("a row whose content moved is a different row")
    func contentIsPartOfTheKey() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7|folded")
        #expect(heights.height(for: "row.7|unfolded") == nil)
    }

    /// The pane made narrower rewraps every paragraph in it, so nothing measured at the old width
    /// is worth keeping. See the header of `TranscriptRowHeights`.
    @Test("a change of width empties the cache")
    func widthInvalidates() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        // Called before the expectation rather than inside it: `reset` is mutating, and `#expect`
        // rewrites its argument into a closure that takes the value immutably.
        let invalidated = heights.reset(width: 600, scale: 1)
        #expect(invalidated)
        #expect(heights.height(for: "row.7") == nil)
        #expect(heights.count == 0)
    }

    @Test("a change of text size empties the cache")
    func scaleInvalidates() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        let invalidated = heights.reset(width: 800, scale: 1.3)
        #expect(invalidated)
        #expect(heights.height(for: "row.7") == nil)
    }

    /// The width and the scale are the cache's rather than each key's, so the cache cannot grow one
    /// entry per row per width the pane has ever been. Coming back to a width is a fresh
    /// measurement, and that is the intended bargain.
    @Test("a width that comes back is not a width that was kept")
    func doesNotHoldEveryWidthItHasSeen() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        heights.reset(width: 600, scale: 1)
        heights.note(180, for: "row.7")
        heights.reset(width: 800, scale: 1)
        #expect(heights.count == 0)
    }

    /// A clip view's own arithmetic lands on fractions, and a row laid out at 831.5 points is the
    /// same row as one laid out at 831.75. Emptying the cache for that would remeasure a whole
    /// conversation for nothing.
    @Test("a fraction of a point is the same width")
    func toleratesAFraction() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831.5, scale: 1)
        heights.note(120, for: "row.7")
        let invalidated = heights.reset(width: 831.75, scale: 1)
        #expect(!invalidated)
        #expect(heights.height(for: "row.7") == 120)
    }

    @Test("a pass that changes nothing says so")
    func noChangeIsNotAnInvalidation() {
        var heights = TranscriptRowHeights()
        let firstPass = heights.reset(width: 800, scale: 1)
        #expect(firstPass)
        let secondPass = heights.reset(width: 800, scale: 1)
        #expect(!secondPass)
    }

    // MARK: - The width that has not arrived yet

    /// A table that has not been laid out reports a width of nought or one, and a row measured
    /// against that is a row one point tall. A table told one point per row is a transcript that is
    /// not there.
    @Test("a width nothing can be drawn at is not a width")
    func refusesAnUnlaidPane() {
        var heights = TranscriptRowHeights()
        let atNought = heights.reset(width: 0, scale: 1)
        #expect(!atNought)
        let atOne = heights.reset(width: 1, scale: 1)
        #expect(!atOne)
        #expect(!heights.isReady)
    }

    @Test("nothing is remembered before a width has arrived")
    func refusesHeightsWithoutAWidth() {
        var heights = TranscriptRowHeights()
        let changed = heights.note(120, for: "row.7")
        #expect(!changed)
        #expect(heights.height(for: "row.7") == nil)
    }

    @Test("the first real width makes the cache ready")
    func becomesReady() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 0, scale: 1)
        #expect(!heights.isReady)
        heights.reset(width: 800, scale: 1)
        #expect(heights.isReady)
    }

    // MARK: - What a drawn row reports

    /// The number arriving is the ideal height of the same content, laid out by the same SwiftUI,
    /// at the width the row was really given. A measurement that disagrees with what is on screen
    /// is a wrong measurement, whichever was taken first.
    @Test("what the row turned out to be outranks what was measured for it")
    func aDrawnRowWins() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        let changed = heights.note(340, for: "row.7")
        #expect(changed)
        #expect(heights.height(for: "row.7") == 340)
    }

    /// A row reports its size on every layout pass. Telling the table to relayout on every one of
    /// those is a transcript that never stops working.
    @Test("a height that has not moved is not news")
    func ignoresAnUnchangedHeight() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        let changed = heights.note(120, for: "row.7")
        #expect(changed)
        let changedAgain = heights.note(120, for: "row.7")
        #expect(!changedAgain)
        // Rounds up to the same 120, so a fraction of a point of drift says nothing either.
        let changedByAFraction = heights.note(119.6, for: "row.7")
        #expect(!changedByAFraction)
    }

    /// This was the several hundred points of blank between the rows of a real conversation: an
    /// empty row drew nothing, said so, and was told it did not count. See the header.
    @Test("nought is a real height and is kept")
    func nothingIsAnAnswer() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        let changed = heights.note(0, for: "row.7")
        #expect(changed)
        #expect(heights.height(for: "row.7") == 0)
    }

    @Test("a height is rounded up, and never below nothing")
    func rounds() {
        #expect(TranscriptRowHeights.rounded(23.1) == 24)
        #expect(TranscriptRowHeights.rounded(24) == 24)
        #expect(TranscriptRowHeights.rounded(-3) == 0)
    }

    // MARK: - A resize, which keeps the numbers and marks them owed

    /// Emptying the cache is a fresh `NSHostingView` per row before the table can be told
    /// anything, which is four seconds on an 1,855 row session. A resize keeps the old numbers as
    /// estimates instead and marks each one as owed a measurement.
    @Test("a resize keeps every height and marks it owed")
    func rewidthEstimates() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        let moved = heights.rewidth(to: 600)
        #expect(moved)
        #expect(heights.height(for: "row.7") == 120)
        #expect(heights.isStale("row.7"))
        #expect(heights.measure?.width == 600)
        #expect(heights.staleCount == 1)
    }

    @Test("a row measured again at the new width stops being owed one")
    func measuringClearsTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        heights.rewidth(to: 600)
        heights.note(180, for: "row.7")
        #expect(!heights.isStale("row.7"))
        #expect(heights.staleCount == 0)
    }

    /// Most rows in a transcript are tool headers and footers whose height does not depend on the
    /// width, so the commonest answer at a new width is the old number. It still has to count as
    /// having been measured, or it is remeasured on every resize for ever.
    @Test("a row that turns out the same height is still no longer owed one")
    func anUnchangedHeightStillSettlesTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        heights.rewidth(to: 600)
        let changed = heights.note(120, for: "row.7")
        #expect(!changed)
        #expect(!heights.isStale("row.7"))
    }

    @Test("a resize to the same width changes nothing")
    func rewidthToTheSameWidth() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        #expect(!heights.rewidth(to: 800.25))
        #expect(!heights.isStale("row.7"))
    }

    /// A pane that has never been laid out has nothing to estimate from, so this is `reset`'s
    /// question rather than one this can answer.
    @Test("a resize before a width has arrived is refused")
    func rewidthNeedsAWidth() {
        var heights = TranscriptRowHeights()
        #expect(!heights.rewidth(to: 800))
        #expect(!heights.isReady)
        heights.reset(width: 800, scale: 1)
        #expect(!heights.rewidth(to: 1))
        #expect(heights.measure?.width == 800)
    }

    @Test("a text size change empties what a resize would have kept")
    func resetClearsTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        heights.rewidth(to: 600)
        heights.reset(width: 600, scale: 1.3)
        #expect(heights.staleCount == 0)
        #expect(heights.height(for: "row.7") == nil)
    }

    @Test("forgetting settles every debt a resize left")
    func forgettingClearsTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        heights.rewidth(to: 600)
        heights.forget()
        #expect(heights.staleCount == 0)
        #expect(!heights.isStale("row.7"))
    }

    // MARK: - The bound

    /// A pane keeps the heights of every conversation it draws, and one pane visits a great many.
    /// Emptying is the whole policy: the cost of hitting it is one conversation measured again.
    @Test("a cache that has grown past its bound starts again")
    func boundsWhatItRemembers() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        for row in 0..<TranscriptRowHeights.mostRows {
            heights.note(Double(row % 400) + 1, for: "row.\(row)")
        }
        #expect(heights.count == TranscriptRowHeights.mostRows)
        heights.note(120, for: "one.too.many")
        #expect(heights.count == 1)
        #expect(heights.height(for: "one.too.many") == 120)
        // The width is kept, because the pane is still the width it was.
        #expect(heights.measure?.width == 800)
    }

    @Test("a row already remembered is not what pushes the cache over")
    func anUpdateIsNotAnInsert() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        for row in 0..<TranscriptRowHeights.mostRows {
            heights.note(Double(row % 400) + 1, for: "row.\(row)")
        }
        heights.note(999, for: "row.0")
        #expect(heights.count == TranscriptRowHeights.mostRows)
        #expect(heights.height(for: "row.0") == 999)
    }

    @Test("half a point is the same width, and one answer says so")
    func oneRuleAboutTheSameWidth() {
        #expect(TranscriptRowHeights.isSameWidth(831.5, 831.75))
        #expect(!TranscriptRowHeights.isSameWidth(831.5, 833))
    }

    // MARK: - Forgetting

    @Test("forgetting empties the cache and keeps the width")
    func forgets() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        heights.forget()
        #expect(heights.height(for: "row.7") == nil)
        #expect(heights.isReady)
        let invalidated = heights.reset(width: 800, scale: 1)
        #expect(!invalidated)
    }
}
