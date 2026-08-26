import Testing
import Foundation
@testable import BloomCore

@Suite("Remembering how tall a transcript row is")
struct TranscriptRowHeightsTests {
    /// A key from one string, which is all these tests need to tell two entries apart. The real
    /// one combines a dozen fields: see `TranscriptContentKey`.
    private func key(_ text: String) -> TranscriptContentKey {
        TranscriptContentKey { $0.combine(text) }
    }

    // MARK: - What the cache is keyed on

    @Test("a row measured once is not measured again")
    func remembersAHeight() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7|assistant"))
        #expect(heights.height(for: key("row.7|assistant")) == 120)
    }

    @Test("a row whose content moved is a different row")
    func contentIsPartOfTheKey() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7|folded"))
        #expect(heights.height(for: key("row.7|unfolded")) == nil)
    }

    /// The pane made narrower rewraps every paragraph in it, so nothing measured at the old width
    /// is worth keeping. See the header of `TranscriptRowHeights`.
    @Test("a change of width empties the cache")
    func widthInvalidates() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7"))
        // Called before the expectation rather than inside it: `reset` is mutating, and `#expect`
        // rewrites its argument into a closure that takes the value immutably.
        let invalidated = heights.reset(width: 600, scale: 1)
        #expect(invalidated)
        #expect(heights.height(for: key("row.7")) == nil)
        #expect(heights.count == 0)
    }

    @Test("a change of text size empties the cache")
    func scaleInvalidates() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7"))
        let invalidated = heights.reset(width: 800, scale: 1.3)
        #expect(invalidated)
        #expect(heights.height(for: key("row.7")) == nil)
    }

    /// The width and the scale are the cache's rather than each key's, so the cache cannot grow one
    /// entry per row per width the pane has ever been. Coming back to a width is a fresh
    /// measurement, and that is the intended bargain.
    @Test("a width that comes back is not a width that was kept")
    func doesNotHoldEveryWidthItHasSeen() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7"))
        heights.reset(width: 600, scale: 1)
        heights.note(180, for: key("row.7"))
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
        heights.note(120, for: key("row.7"))
        let invalidated = heights.reset(width: 831.75, scale: 1)
        #expect(!invalidated)
        #expect(heights.height(for: key("row.7")) == 120)
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
        let changed = heights.note(120, for: key("row.7"))
        #expect(!changed)
        #expect(heights.height(for: key("row.7")) == nil)
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
        heights.note(120, for: key("row.7"))
        let changed = heights.note(340, for: key("row.7"))
        #expect(changed)
        #expect(heights.height(for: key("row.7")) == 340)
    }

    /// A row reports its size on every layout pass. Telling the table to relayout on every one of
    /// those is a transcript that never stops working.
    @Test("a height that has not moved is not news")
    func ignoresAnUnchangedHeight() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        let changed = heights.note(120, for: key("row.7"))
        #expect(changed)
        let changedAgain = heights.note(120, for: key("row.7"))
        #expect(!changedAgain)
        // Rounds up to the same 120, so a fraction of a point of drift says nothing either.
        let changedByAFraction = heights.note(119.6, for: key("row.7"))
        #expect(!changedByAFraction)
    }

    /// This was the several hundred points of blank between the rows of a real conversation: an
    /// empty row drew nothing, said so, and was told it did not count. See the header.
    @Test("nought is a real height and is kept")
    func nothingIsAnAnswer() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        let changed = heights.note(0, for: key("row.7"))
        #expect(changed)
        #expect(heights.height(for: key("row.7")) == 0)
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
        heights.note(120, for: key("row.7"))
        let moved = heights.rewidth(to: 600)
        #expect(moved)
        #expect(heights.height(for: key("row.7")) == 120)
        #expect(heights.isStale(key("row.7")))
        #expect(heights.measure?.width == 600)
        #expect(heights.staleCount == 1)
    }

    @Test("a row measured again at the new width stops being owed one")
    func measuringClearsTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7"))
        heights.rewidth(to: 600)
        heights.note(180, for: key("row.7"))
        #expect(!heights.isStale(key("row.7")))
        #expect(heights.staleCount == 0)
    }

    /// Most rows in a transcript are tool headers and footers whose height does not depend on the
    /// width, so the commonest answer at a new width is the old number. It still has to count as
    /// having been measured, or it is remeasured on every resize for ever.
    @Test("a row that turns out the same height is still no longer owed one")
    func anUnchangedHeightStillSettlesTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7"))
        heights.rewidth(to: 600)
        let changed = heights.note(120, for: key("row.7"))
        #expect(!changed)
        #expect(!heights.isStale(key("row.7")))
    }

    @Test("a resize to the same width changes nothing")
    func rewidthToTheSameWidth() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7"))
        let rewidened = heights.rewidth(to: 800.25)
        #expect(!rewidened)
        #expect(!heights.isStale(key("row.7")))
    }

    /// A pane that has never been laid out has nothing to estimate from, so this is `reset`'s
    /// question rather than one this can answer.
    @Test("a resize before a width has arrived is refused")
    func rewidthNeedsAWidth() {
        var heights = TranscriptRowHeights()
        let rewidened = heights.rewidth(to: 800)
        #expect(!rewidened)
        #expect(!heights.isReady)
        heights.reset(width: 800, scale: 1)
        let rewidened2 = heights.rewidth(to: 1)
        #expect(!rewidened2)
        #expect(heights.measure?.width == 800)
    }

    @Test("a text size change empties what a resize would have kept")
    func resetClearsTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7"))
        heights.rewidth(to: 600)
        heights.reset(width: 600, scale: 1.3)
        #expect(heights.staleCount == 0)
        #expect(heights.height(for: key("row.7")) == nil)
    }

    @Test("forgetting settles every debt a resize left")
    func forgettingClearsTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: key("row.7"))
        heights.rewidth(to: 600)
        heights.forget()
        #expect(heights.staleCount == 0)
        #expect(!heights.isStale(key("row.7")))
    }

    // MARK: - What an unmeasured row is worth

    /// **Nothing is measured up front.** A table asks for every row it holds, so a pane arriving
    /// at a conversation used to build an `NSHostingView` for each of the four hundred rows in its
    /// window, none of which anybody saw.
    @Test("a row nobody has measured is assumed rather than refused")
    func assumesAnUnmeasuredRow() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        #expect(heights.height(for: key("row.7")) == nil)
        #expect(heights.assumed(for: key("row.7")) == TranscriptRowHeights.assumedRowHeight)
    }

    @Test("what has been measured is what the rest is assumed to be")
    func assumesTheMeanOfWhatIsKnown() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(100, for: key("row.1"))
        heights.note(200, for: key("row.2"))
        #expect(heights.estimate == 150)
        #expect(heights.assumed(for: key("row.99")) == 150)
        // And the measured ones are still themselves.
        #expect(heights.assumed(for: key("row.1")) == 100)
    }

    /// **A row that is going to draw nothing is answered, not estimated.** Most of a session is
    /// stream events with no view in them, and the mean is the worst answer for one: too tall by
    /// the whole mean, three or four times between every pair of tool calls, and then corrected the
    /// moment it is drawn. See `TranscriptRowInk`.
    @Test("a row that draws nothing is worth nothing before it is drawn")
    func assumesNothingForABlankRow() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(100, for: key("row.1"))
        #expect(heights.assumed(for: key("blank"), drawsNothing: true) == 0)
        #expect(heights.assumed(for: key("blank")) == 100)
    }

    /// The claim is about a row nobody has drawn. A measurement outranks it, because being wrong
    /// about this has to cost one correction rather than a row stuck at nothing.
    @Test("a measurement outranks the claim that a row draws nothing")
    func measurementBeatsTheClaim() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(42, for: key("row.1"))
        #expect(heights.assumed(for: key("row.1"), drawsNothing: true) == 42)
    }

    /// **The rows that drew nothing are not in the mean.** A session where most rows draw nothing
    /// made the mean several times too small for the rows it is actually asked about, which is the
    /// other half of a screen of wrong heights.
    @Test("rows that drew nothing do not drag the estimate down")
    func noughtsAreNotInTheMean() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(100, for: key("row.1"))
        heights.note(200, for: key("row.2"))
        for row in 0..<50 { heights.note(0, for: key("blank.\(row)")) }
        #expect(heights.estimate == 150)
        // The noughts are still remembered, and still nought.
        #expect(heights.height(for: key("blank.7")) == 0)
        #expect(heights.count == 52)
    }

    /// A row that drew something and then drew nothing leaves the mean as if it had never been in
    /// it, which is what a fold closing or a tail emptying does.
    @Test("a row that becomes nothing leaves the mean")
    func aRowThatEmptiesLeavesTheMean() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(100, for: key("row.1"))
        heights.note(300, for: key("row.2"))
        heights.note(0, for: key("row.2"))
        #expect(heights.estimate == 100)
    }

    /// **The estimate stops moving, because the document's total depends on it.** A table caches
    /// every height it is told, so a drifting estimate turns each wholesale re-ask into one jump of
    /// `unmeasured x drift`: measured at 32,218 points on a 2,981 row conversation, which is the
    /// height of the whole document.
    @Test("the estimate settles and then holds still")
    func settlesAndHolds() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(100, for: key("row.\(row)"))
        }
        #expect(heights.estimate == 100)
        // Everything after this is measured on its own account and changes nothing for the rows
        // nobody has drawn.
        for row in 0..<200 { heights.note(900, for: key("late.\(row)")) }
        #expect(heights.estimate == 100)
        #expect(heights.assumed(for: key("never.drawn")) == 100)
    }

    /// Before it settles it still tracks, because the first screenful is all there is to go on and
    /// a constant is worse than a mean of two real rows.
    @Test("the estimate tracks until it settles")
    func tracksUntilItSettles() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(100, for: key("row.1"))
        #expect(heights.estimate == 100)
        heights.note(300, for: key("row.2"))
        #expect(heights.estimate == 200)
    }

    /// A width or a text size change empties the cache, and the number formed at the old one goes
    /// with it. A paragraph at another size is not an estimate of anything.
    @Test("emptying the cache unsettles the estimate")
    func settlingIsEmptiedWithTheCache() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(100, for: key("row.\(row)"))
        }
        heights.forget()
        #expect(heights.estimate == TranscriptRowHeights.assumedRowHeight)
        heights.note(40, for: key("fresh"))
        #expect(heights.estimate == 40)
    }

    /// The rows that drew nothing are not what settles it either. A session where most rows draw
    /// nothing would otherwise settle on a number formed from almost no real rows.
    @Test("noughts do not settle the estimate")
    func noughtsDoNotSettleIt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        for row in 0..<200 { heights.note(0, for: key("blank.\(row)")) }
        heights.note(100, for: key("row.1"))
        #expect(heights.estimate == 100)
        heights.note(300, for: key("row.2"))
        // Two drawn rows is not a screenful, so it is still tracking.
        #expect(heights.estimate == 200)
    }

    /// The running total has to survive an overwrite, which is what every drawn row does to what
    /// was measured for it off screen.
    @Test("a row measured again does not count twice")
    func meanFollowsAnOverwrite() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(100, for: key("row.1"))
        heights.note(300, for: key("row.1"))
        #expect(heights.estimate == 300)
    }

    @Test("a cache that has been emptied assumes nothing it used to know")
    func meanIsEmptiedWithTheCache() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(400, for: key("row.1"))
        heights.forget()
        #expect(heights.estimate == TranscriptRowHeights.assumedRowHeight)
    }

    /// A resize keeps its numbers, so it keeps the estimate they make up: the rows it has not
    /// measured yet are still better guessed at from this conversation than from a constant.
    @Test("a resize keeps the estimate as well as the heights")
    func meanSurvivesAResize() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(100, for: key("row.1"))
        heights.note(200, for: key("row.2"))
        heights.rewidth(to: 600)
        #expect(heights.estimate == 150)
    }

    // MARK: - The bound

    /// A pane keeps the heights of every conversation it draws, and one pane visits a great many.
    /// Emptying is the whole policy: the cost of hitting it is one conversation measured again.
    @Test("a cache that has grown past its bound starts again")
    func boundsWhatItRemembers() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        for row in 0..<TranscriptRowHeights.mostRows {
            heights.note(Double(row % 400) + 1, for: key("row.\(row)"))
        }
        #expect(heights.count == TranscriptRowHeights.mostRows)
        heights.note(120, for: key("one.too.many"))
        #expect(heights.count == 1)
        #expect(heights.height(for: key("one.too.many")) == 120)
        // The width is kept, because the pane is still the width it was.
        #expect(heights.measure?.width == 800)
    }

    @Test("a row already remembered is not what pushes the cache over")
    func anUpdateIsNotAnInsert() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        for row in 0..<TranscriptRowHeights.mostRows {
            heights.note(Double(row % 400) + 1, for: key("row.\(row)"))
        }
        heights.note(999, for: key("row.0"))
        #expect(heights.count == TranscriptRowHeights.mostRows)
        #expect(heights.height(for: key("row.0")) == 999)
    }

    /// The check that a row is the height it draws at asks this, and so does `note`. Two answers
    /// would mean a height the cache calls unchanged being reported as a row drawn wrong.
    @Test("half a point is the same height, and it is the slack a note is filed under")
    func oneRuleAboutTheSameHeight() {
        #expect(TranscriptRowHeights.isSameHeight(24, 24.4))
        #expect(!TranscriptRowHeights.isSameHeight(24, 25))
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(24, for: key("row.1"))
        // Rounded up to 25, which is a point away and therefore news.
        let news = heights.note(24.4, for: key("row.1"))
        #expect(news)
        let again = heights.note(25, for: key("row.1"))
        #expect(!again)
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
        heights.note(120, for: key("row.7"))
        heights.forget()
        #expect(heights.height(for: key("row.7")) == nil)
        #expect(heights.isReady)
        let invalidated = heights.reset(width: 800, scale: 1)
        #expect(!invalidated)
    }
}
