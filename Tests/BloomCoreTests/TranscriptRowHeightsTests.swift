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
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7|assistant"), measuredAt: 800)
        #expect(heights.height(for: key("row.7|assistant")) == 120)
    }

    @Test("a row whose content moved is a different row")
    func contentIsPartOfTheKey() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7|folded"), measuredAt: 800)
        #expect(heights.height(for: key("row.7|unfolded")) == nil)
    }

    /// The pane made narrower rewraps every paragraph in it, so nothing measured at the old width
    /// is worth keeping. See the header of `TranscriptRowHeights`.
    @Test("a change of width empties the cache")
    func widthInvalidates() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        // Called before the expectation rather than inside it: `reset` is mutating, and `#expect`
        // rewrites its argument into a closure that takes the value immutably.
        let invalidated = heights.reset(width: 600, scale: 1, leading: 1.7)
        #expect(invalidated)
        #expect(heights.height(for: key("row.7")) == nil)
        #expect(heights.count == 0)
    }

    @Test("a change of text size empties the cache")
    func scaleInvalidates() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        let invalidated = heights.reset(width: 800, scale: 1.3, leading: 1.7)
        #expect(invalidated)
        #expect(heights.height(for: key("row.7")) == nil)
    }

    /// The setting the owner asked for moves every measured row in the transcript, and a cache
    /// that was not told would hand the table the old numbers: rows drawn on top of each other,
    /// which is a bug this codebase has already paid for once over the text size.
    @Test("a change of line height empties the cache")
    func leadingInvalidates() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        let invalidated = heights.reset(width: 800, scale: 1, leading: 1.4)
        #expect(invalidated)
        #expect(heights.height(for: key("row.7")) == nil)
    }

    /// A resize keeps its numbers as estimates on purpose. A line height does not survive one:
    /// `rewidth` carries the leading forward untouched, so a paragraph led differently can only
    /// arrive through `reset`.
    @Test("a resize carries the line height it was already at")
    func rewidthKeepsTheLeading() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.85)
        let moved = heights.rewidth(to: 600)
        #expect(moved)
        #expect(heights.measure?.leading == 1.85)
    }

    /// The width and the scale are the cache's rather than each key's, so the cache cannot grow one
    /// entry per row per width the pane has ever been. Coming back to a width is a fresh
    /// measurement, and that is the intended bargain.
    @Test("a width that comes back is not a width that was kept")
    func doesNotHoldEveryWidthItHasSeen() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        heights.reset(width: 600, scale: 1, leading: 1.7)
        heights.note(180, for: key("row.7"), measuredAt: 600)
        heights.reset(width: 800, scale: 1, leading: 1.7)
        #expect(heights.count == 0)
    }

    /// A clip view's own arithmetic lands on fractions, and a row laid out at 831.5 points is the
    /// same row as one laid out at 831.75. Emptying the cache for that would remeasure a whole
    /// conversation for nothing.
    @Test("a fraction of a point is the same width")
    func toleratesAFraction() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831.5, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 831.5)
        let invalidated = heights.reset(width: 831.75, scale: 1, leading: 1.7)
        #expect(!invalidated)
        #expect(heights.height(for: key("row.7")) == 120)
    }

    @Test("a pass that changes nothing says so")
    func noChangeIsNotAnInvalidation() {
        var heights = TranscriptRowHeights()
        let firstPass = heights.reset(width: 800, scale: 1, leading: 1.7)
        #expect(firstPass)
        let secondPass = heights.reset(width: 800, scale: 1, leading: 1.7)
        #expect(!secondPass)
    }

    // MARK: - The width that has not arrived yet

    /// A table that has not been laid out reports a width of nought or one, and a row measured
    /// against that is a row one point tall. A table told one point per row is a transcript that is
    /// not there.
    @Test("a width nothing can be drawn at is not a width")
    func refusesAnUnlaidPane() {
        var heights = TranscriptRowHeights()
        let atNought = heights.reset(width: 0, scale: 1, leading: 1.7)
        #expect(!atNought)
        let atOne = heights.reset(width: 1, scale: 1, leading: 1.7)
        #expect(!atOne)
        #expect(!heights.isReady)
    }

    @Test("nothing is remembered before a width has arrived")
    func refusesHeightsWithoutAWidth() {
        var heights = TranscriptRowHeights()
        // A report at a perfectly good width, refused because the cache is for no width at all
        // and a height is a fact about one. See `isEvidence`.
        let changed = heights.note(120, for: key("row.7"), measuredAt: 800)
        #expect(!changed)
        #expect(heights.height(for: key("row.7")) == nil)
    }

    @Test("the first real width makes the cache ready")
    func becomesReady() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 0, scale: 1, leading: 1.7)
        #expect(!heights.isReady)
        heights.reset(width: 800, scale: 1, leading: 1.7)
        #expect(heights.isReady)
    }

    // MARK: - What a drawn row reports

    /// The number arriving is the ideal height of the same content, laid out by the same SwiftUI,
    /// at the width the row was really given. A measurement that disagrees with what is on screen
    /// is a wrong measurement, whichever was taken first.
    @Test("what the row turned out to be outranks what was measured for it")
    func aDrawnRowWins() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        let changed = heights.note(340, for: key("row.7"), measuredAt: 800)
        #expect(changed)
        #expect(heights.height(for: key("row.7")) == 340)
    }

    /// A row reports its size on every layout pass. Telling the table to relayout on every one of
    /// those is a transcript that never stops working.
    @Test("a height that has not moved is not news")
    func ignoresAnUnchangedHeight() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        let changed = heights.note(120, for: key("row.7"), measuredAt: 800)
        #expect(changed)
        let changedAgain = heights.note(120, for: key("row.7"), measuredAt: 800)
        #expect(!changedAgain)
        // Rounds up to the same 120, so a fraction of a point of drift says nothing either.
        let changedByAFraction = heights.note(119.6, for: key("row.7"), measuredAt: 800)
        #expect(!changedByAFraction)
    }

    /// This was the several hundred points of blank between the rows of a real conversation: an
    /// empty row drew nothing, said so, and was told it did not count. See the header.
    @Test("nought is a real height and is kept")
    func nothingIsAnAnswer() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        let changed = heights.note(0, for: key("row.7"), measuredAt: 800)
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
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
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
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        heights.rewidth(to: 600)
        heights.note(180, for: key("row.7"), measuredAt: 600)
        #expect(!heights.isStale(key("row.7")))
        #expect(heights.staleCount == 0)
    }

    /// Most rows in a transcript are tool headers and footers whose height does not depend on the
    /// width, so the commonest answer at a new width is the old number. It still has to count as
    /// having been measured, or it is remeasured on every resize for ever.
    @Test("a row that turns out the same height is still no longer owed one")
    func anUnchangedHeightStillSettlesTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        heights.rewidth(to: 600)
        let changed = heights.note(120, for: key("row.7"), measuredAt: 600)
        #expect(!changed)
        #expect(!heights.isStale(key("row.7")))
    }

    @Test("a resize to the same width changes nothing")
    func rewidthToTheSameWidth() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
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
        heights.reset(width: 800, scale: 1, leading: 1.7)
        let rewidened2 = heights.rewidth(to: 1)
        #expect(!rewidened2)
        #expect(heights.measure?.width == 800)
    }

    @Test("a text size change empties what a resize would have kept")
    func resetClearsTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        heights.rewidth(to: 600)
        heights.reset(width: 600, scale: 1.3, leading: 1.7)
        #expect(heights.staleCount == 0)
        #expect(heights.height(for: key("row.7")) == nil)
    }

    @Test("forgetting settles every debt a resize left")
    func forgettingClearsTheDebt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
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
        heights.reset(width: 800, scale: 1, leading: 1.7)
        #expect(heights.height(for: key("row.7")) == nil)
        #expect(heights.assumed(for: key("row.7")) == TranscriptRowHeights.assumedRowHeight)
    }

    /// The MIDDLE of what has been measured, and it was the mean. See `Running.middle`: a
    /// transcript's row heights run from nothing to ten thousand points, so a mean over a handful
    /// of them is whatever the longest answer in the sample says.
    @Test("what has been measured is what the rest is assumed to be")
    func assumesTheMiddleOfWhatIsKnown() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(100, for: key("row.1"), measuredAt: 800)
        heights.note(200, for: key("row.2"), measuredAt: 800)
        #expect(heights.estimate == 100)
        #expect(heights.assumed(for: key("row.99")) == 100)
        // And the measured ones are still themselves.
        #expect(heights.assumed(for: key("row.1")) == 100)
    }

    // MARK: - Whether a row is worth a view

    /// **The rule behind giving a row no view at all.** A table builds an `NSHostingView` with a
    /// SwiftUI graph of its own for every row in the visible rect, and sixty per cent of a real
    /// session draws nothing. Only a row that has been MEASURED at nought is silenced, because
    /// then nothing is owed a correction.
    @Test("a row measured at nothing is known to draw nothing")
    func measuredNothingIsNothing() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(0, for: key("blank"), measuredAt: 800)
        #expect(heights.measuredNothing(key("blank")))
    }

    /// **The one that keeps the gaps from coming back.** A row nobody has measured is not known to
    /// draw nothing, whatever `TranscriptRowInk` guessed about it: it is built, it reports, and
    /// that report is what would catch the guess being wrong.
    @Test("a row nobody has measured is not known to draw nothing")
    func unmeasuredIsNotNothing() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        #expect(!heights.measuredNothing(key("never.drawn")))
        // Even though it is answered as nought, which is a claim rather than a measurement.
        #expect(heights.assumed(for: key("never.drawn"), drawsNothing: true) == 0)
        #expect(!heights.measuredNothing(key("never.drawn")))
    }

    /// A row that drew something is not silenced, and a row rounded up to a point is something.
    /// `note` rounds UP, so four tenths of a point is remembered as one and is a row with a view.
    @Test("anything at all is not nothing")
    func somethingIsNotNothing() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(24, for: key("row.1"), measuredAt: 800)
        heights.note(0.4, for: key("row.2"), measuredAt: 800)
        #expect(!heights.measuredNothing(key("row.1")))
        #expect(!heights.measuredNothing(key("row.2")))
        #expect(heights.height(for: key("row.2")) == 1)
    }

    /// **A row that gains content is built again.** The cache is keyed on what the row draws, so a
    /// row that was nothing and now has something is a different key, which nobody has measured.
    /// This is why silencing a row cannot bring the blank between two rows back.
    @Test("a row that gains content is not the row that drew nothing")
    func gainingContentMissesTheCache() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(0, for: key("row.7.empty"), measuredAt: 800)
        #expect(heights.measuredNothing(key("row.7.empty")))
        // The same row, now with something in it, and therefore a different content key.
        #expect(!heights.measuredNothing(key("row.7.full")))
    }

    /// Emptying the cache un-silences everything, which is what a text size change comes to: every
    /// row is built again, reports again, and the ones that draw nothing go quiet again.
    @Test("emptying the cache stops any row being known to draw nothing")
    func forgettingUnsilencesEverything() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(0, for: key("blank"), measuredAt: 800)
        heights.forget()
        #expect(!heights.measuredNothing(key("blank")))
    }

    /// **A row that draws nothing is answered, not estimated.** Most of a session is
    /// stream events with no view in them, and the mean is the worst answer for one: too tall by
    /// the whole mean, three or four times between every pair of tool calls, and then corrected the
    /// moment it is drawn. See `TranscriptRowInk`.
    @Test("a row that draws nothing is worth nothing before it is drawn")
    func assumesNothingForABlankRow() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(100, for: key("row.1"), measuredAt: 800)
        #expect(heights.assumed(for: key("blank"), drawsNothing: true) == 0)
        #expect(heights.assumed(for: key("blank")) == 100)
    }

    /// The claim is about a row nobody has drawn. A measurement outranks it, because being wrong
    /// about this has to cost one correction rather than a row stuck at nothing.
    @Test("a measurement outranks the claim that a row draws nothing")
    func measurementBeatsTheClaim() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(42, for: key("row.1"), measuredAt: 800)
        #expect(heights.assumed(for: key("row.1"), drawsNothing: true) == 42)
    }

    /// **The rows that drew nothing are not in the mean.** A session where most rows draw nothing
    /// made the mean several times too small for the rows it is actually asked about, which is the
    /// other half of a screen of wrong heights.
    @Test("rows that drew nothing do not drag the estimate down")
    func noughtsAreNotInTheMean() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(100, for: key("row.1"), measuredAt: 800)
        heights.note(200, for: key("row.2"), measuredAt: 800)
        for row in 0..<50 { heights.note(0, for: key("blank.\(row)"), measuredAt: 800) }
        #expect(heights.estimate == 100)
        // The noughts are still remembered, and still nought.
        #expect(heights.height(for: key("blank.7")) == 0)
        #expect(heights.count == 52)
    }

    /// A row that drew something and then drew nothing leaves the mean as if it had never been in
    /// it, which is what a fold closing or a tail emptying does.
    @Test("a row that becomes nothing leaves the mean")
    func aRowThatEmptiesLeavesTheMean() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(100, for: key("row.1"), measuredAt: 800)
        heights.note(300, for: key("row.2"), measuredAt: 800)
        heights.note(0, for: key("row.2"), measuredAt: 800)
        #expect(heights.estimate == 100)
    }

    /// **The estimate stops moving, because the document's total depends on it.** A table caches
    /// every height it is told, so a drifting estimate turns each wholesale re-ask into one jump of
    /// `unmeasured x drift`: measured at 32,218 points on a 2,981 row conversation, which is the
    /// height of the whole document.
    @Test("the estimate settles and then holds still")
    func settlesAndHolds() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(100, for: key("row.\(row)"), measuredAt: 800)
        }
        #expect(heights.estimate == 100)
        // Everything after this is measured on its own account and changes nothing for the rows
        // nobody has drawn, until the sample it was formed from has doubled. Twenty three of these
        // is forty seven drawn rows against the twenty four it settled from, so it holds even
        // though every one of them disagrees.
        for row in 0..<23 { heights.note(900, for: key("late.\(row)"), measuredAt: 800) }
        #expect(heights.estimate == 100)
        #expect(heights.assumed(for: key("never.drawn")) == 100)
    }

    /// **The screenful it settles from is the least representative one in the session**: a pane
    /// arrives at the live end, so the sample is the newest answer, which is the longest prose
    /// there is. Measured, that left a document half again taller than the truth with nothing able
    /// to take the number again.
    @Test("a settled estimate formed off a bad screenful is taken again")
    func resettlesWhenItIsBadlyOut() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        // The tail: a screenful of tall rows, which settles it at 400.
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(400, for: key("tail.\(row)"), measuredAt: 800)
        }
        #expect(heights.estimate == 400)
        // The conversation behind it, which is what the session is really made of. Nothing moves
        // until the sample has doubled, however wrong the held number is: twenty three of these
        // leaves forty seven drawn rows against the twenty four it settled from.
        for row in 0..<23 { heights.note(20, for: key("row.\(row)"), measuredAt: 800) }
        #expect(heights.estimate == 400)
        // The forty eighth doubles it, and twenty is what half the rows in this conversation
        // actually are. The mean this used to take answered 210, which is a height no row in the
        // sample has and which every unmeasured row would have been drawn at.
        heights.note(20, for: key("row.23"), measuredAt: 800)
        #expect(heights.estimate == 20)
    }

    /// A number that is nearly right must not move, because the whole point of settling is that a
    /// wholesale re-ask cashes in whatever drift there has been since the last one.
    @Test("a settled estimate that is nearly right is left alone")
    func doesNotResettleForSmallDrift() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(100, for: key("row.\(row)"), measuredAt: 800)
        }
        #expect(heights.estimate == 100)
        // A tenth out over hundreds of rows, which is inside the drift this tolerates.
        for row in 0..<400 { heights.note(110, for: key("more.\(row)"), measuredAt: 800) }
        #expect(heights.estimate == 100)
    }

    /// Before it settles it still tracks, because the first screenful is all there is to go on and
    /// a constant is worse than two real rows.
    ///
    /// **What it no longer does is track the outlier.** A second row three times the first used to
    /// move the answer to 200, a height neither row has; the middle of the two is the shorter one,
    /// and the taller row is measured on its own account anyway.
    @Test("the estimate tracks until it settles")
    func tracksUntilItSettles() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(100, for: key("row.1"), measuredAt: 800)
        #expect(heights.estimate == 100)
        heights.note(300, for: key("row.2"), measuredAt: 800)
        #expect(heights.estimate == 100)
    }

    /// A width or a text size change empties the cache, and the number formed at the old one goes
    /// with it. A paragraph at another size is not an estimate of anything.
    @Test("emptying the cache unsettles the estimate")
    func settlingIsEmptiedWithTheCache() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(100, for: key("row.\(row)"), measuredAt: 800)
        }
        heights.forget()
        #expect(heights.estimate == TranscriptRowHeights.assumedRowHeight)
        heights.note(40, for: key("fresh"), measuredAt: 800)
        #expect(heights.estimate == 40)
    }

    /// The rows that drew nothing are not what settles it either. A session where most rows draw
    /// nothing would otherwise settle on a number formed from almost no real rows.
    @Test("noughts do not settle the estimate")
    func noughtsDoNotSettleIt() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<200 { heights.note(0, for: key("blank.\(row)"), measuredAt: 800) }
        heights.note(100, for: key("row.1"), measuredAt: 800)
        #expect(heights.estimate == 100)
        heights.note(300, for: key("row.2"), measuredAt: 800)
        // Two drawn rows is not a screenful, so it is still tracking.
        #expect(heights.estimate == 100)
    }

    /// The running total has to survive an overwrite, which is what every drawn row does to what
    /// was measured for it off screen.
    @Test("a row measured again does not count twice")
    func meanFollowsAnOverwrite() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(100, for: key("row.1"), measuredAt: 800)
        heights.note(300, for: key("row.1"), measuredAt: 800)
        #expect(heights.estimate == 300)
    }

    @Test("a cache that has been emptied assumes nothing it used to know")
    func meanIsEmptiedWithTheCache() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(400, for: key("row.1"), measuredAt: 800)
        heights.forget()
        #expect(heights.estimate == TranscriptRowHeights.assumedRowHeight)
    }

    /// A resize keeps its numbers, so it keeps the estimate they make up: the rows it has not
    /// measured yet are still better guessed at from this conversation than from a constant.
    @Test("a resize keeps the estimate as well as the heights")
    func meanSurvivesAResize() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(100, for: key("row.1"), measuredAt: 800)
        heights.note(200, for: key("row.2"), measuredAt: 800)
        heights.rewidth(to: 600)
        #expect(heights.estimate == 100)
    }

    // MARK: - The estimate belongs to the conversation on screen

    /// **The reader's report: "switching between workspaces sometimes renders the conversation
    /// wrongly, with gigantic gaps."**
    ///
    /// A pane that had been reading prose settles the estimate at 400. Every row of the tool-heavy
    /// workspace it is pointed at next is a row nobody has measured, so every one of them was laid
    /// out at 400 against a true 24: on the fifteen inked rows of one screen that is 5,640 points
    /// of blank.
    @Test("the conversation being left does not say how tall the arriving one's rows are")
    func theEstimateDoesNotCrossAWorkspaceSwitch() {
        var heights = TranscriptRowHeights()
        heights.showing(SessionID("prose"))
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<2_000 { heights.note(400, for: key("prose.\(row)"), measuredAt: 800) }
        #expect(heights.estimate == 400)

        let switched = heights.showing(SessionID("tools"))
        #expect(switched)
        #expect(heights.assumed(for: key("tools.0")) == TranscriptRowHeights.assumedRowHeight)
    }

    /// And it settles on what this conversation is really made of, which is the half the old
    /// number could not do: `resettleDrift` only takes the mean again once the sample has doubled,
    /// and the sample was the two thousand rows of the conversation being left.
    @Test("the estimate settles again for the conversation arriving")
    func theEstimateSettlesForEachConversation() {
        var heights = TranscriptRowHeights()
        heights.showing(SessionID("prose"))
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<2_000 { heights.note(400, for: key("prose.\(row)"), measuredAt: 800) }
        heights.showing(SessionID("tools"))
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(24, for: key("tools.\(row)"), measuredAt: 800)
        }
        #expect(heights.estimate == 24)
        #expect(heights.assumed(for: key("tools.never.drawn")) == 24)
    }

    /// The heights themselves are what makes coming back to a conversation free, so a switch keeps
    /// every one of them. See the header: this is the whole reason the cache outlives the
    /// conversation it was filled for.
    @Test("a switch keeps every height that was measured")
    func aSwitchKeepsTheHeights() {
        var heights = TranscriptRowHeights()
        heights.showing(SessionID("one"))
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("one.row.7"), measuredAt: 800)
        heights.showing(SessionID("two"))
        #expect(heights.height(for: key("one.row.7")) == 120)
        let back = heights.showing(SessionID("one"))
        #expect(back)
        #expect(heights.height(for: key("one.row.7")) == 120)
    }

    /// **A returning reader's rows are the only evidence that visit has**, and they are all
    /// measured already. Each reports the height it draws at, which is no news to the cache, so a
    /// sample counted after the news test would be a sample of nothing at all and the conversation
    /// would estimate from a constant for the whole visit.
    @Test("rows the cache already knows still form the estimate")
    func aReturningConversationFormsItsOwnEstimate() {
        var heights = TranscriptRowHeights()
        heights.showing(SessionID("one"))
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(300, for: key("one.\(row)"), measuredAt: 800)
        }
        heights.showing(SessionID("two"))
        let back = heights.showing(SessionID("one"))
        #expect(back)
        #expect(heights.estimate == TranscriptRowHeights.assumedRowHeight)
        // The screen the reader lands on, reporting what it has always been.
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(300, for: key("one.\(row)"), measuredAt: 800)
        }
        #expect(heights.estimate == 300)
    }

    /// One contribution per row, not one per report. The streaming tail says itself on every frame
    /// of a turn, and a sample that counted each of those would be a mean of one row.
    @Test("a row that reports twice is in the sample once")
    func aRowIsSampledOnce() {
        var heights = TranscriptRowHeights()
        heights.showing(SessionID("one"))
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(100, for: key("row.1"), measuredAt: 800)
        for step in 1...20 { heights.note(Double(100 + step * 10), for: key("tail"), measuredAt: 800) }
        // The tail's last word and one other row: 300 and 100, whose middle is 100. Counted per
        // report rather than per row it would be a sample of twenty one tail heights.
        #expect(heights.estimate == 100)
    }

    @Test("saying the same conversation again changes nothing")
    func sayingTheSameConversationIsIdempotent() {
        var heights = TranscriptRowHeights()
        heights.showing(SessionID("one"))
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(300, for: key("one.\(row)"), measuredAt: 800)
        }
        let again = heights.showing(SessionID("one"))
        #expect(!again)
        #expect(heights.estimate == 300)
    }

    // MARK: - The bound

    /// A pane keeps the heights of every conversation it draws, and one pane visits a great many.
    /// Emptying is the whole policy: the cost of hitting it is one conversation measured again.
    @Test("a cache that has grown past its bound starts again")
    func boundsWhatItRemembers() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.mostRows {
            heights.note(Double(row % 400) + 1, for: key("row.\(row)"), measuredAt: 800)
        }
        #expect(heights.count == TranscriptRowHeights.mostRows)
        heights.note(120, for: key("one.too.many"), measuredAt: 800)
        #expect(heights.count == 1)
        #expect(heights.height(for: key("one.too.many")) == 120)
        // The width is kept, because the pane is still the width it was.
        #expect(heights.measure?.width == 800)
    }

    @Test("a row already remembered is not what pushes the cache over")
    func anUpdateIsNotAnInsert() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.mostRows {
            heights.note(Double(row % 400) + 1, for: key("row.\(row)"), measuredAt: 800)
        }
        heights.note(999, for: key("row.0"), measuredAt: 800)
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
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(24, for: key("row.1"), measuredAt: 800)
        // Rounded up to 25, which is a point away and therefore news.
        let news = heights.note(24.4, for: key("row.1"), measuredAt: 800)
        #expect(news)
        let again = heights.note(25, for: key("row.1"), measuredAt: 800)
        #expect(!again)
    }

    @Test("half a point is the same width, and one answer says so")
    func oneRuleAboutTheSameWidth() {
        #expect(TranscriptRowHeights.isSameWidth(831.5, 831.75))
        #expect(!TranscriptRowHeights.isSameWidth(831.5, 833))
    }

    // MARK: - What is still owed a measurement

    @Test("a row nobody has measured is owed one")
    func anUnknownRowIsOwed() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        #expect(heights.needsMeasuring(key("row.7"), redrawsItself: false))
    }

    @Test("a stored row that has been measured is not owed another")
    func aMeasuredRowIsNotOwed() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        #expect(!heights.needsMeasuring(key("row.7"), redrawsItself: false))
    }

    /// A row measured at a width the pane no longer has is owed one at the width it does have.
    @Test("a row measured at another width is owed another")
    func aStaleRowIsOwed() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        let moved = heights.rewidth(to: 600)
        #expect(moved)
        #expect(heights.needsMeasuring(key("row.7"), redrawsItself: false))
    }

    /// **The blank between the last turn's footer and the composer, written down.** The streaming
    /// tail's key carries the session and nothing else, so it is the same key whether the tail is
    /// several hundred points of a running answer or nothing at all between turns. A hit for it is
    /// not what it draws, it is what it drew when somebody last looked, and a workspace switch is
    /// exactly the gap in which that stops being true.
    @Test("an entry that redraws itself is always owed a measurement")
    func anEntryThatRedrawsItselfIsAlwaysOwed() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(480, for: key("streaming.session-a"), measuredAt: 800)
        #expect(heights.height(for: key("streaming.session-a")) == 480)
        #expect(heights.needsMeasuring(key("streaming.session-a"), redrawsItself: true))
    }

    /// **And the other half of that, which is the case a reader of the two callers flagged.** A
    /// fold's line is not a stored row and it holds no sequence number, so the obvious reading is
    /// that it must redraw itself like the tail above. It must not: everything a fold draws is
    /// hashed into its key, so a measurement filed under one is the answer until the key moves.
    /// Getting that wrong costs twice over, because `TranscriptTable.viewFor` also refuses to
    /// silence an entry that redraws itself, and a fold that has been measured at nothing is
    /// exactly the entry worth silencing: there is one per run of tool calls in the session, and
    /// most of them have nothing to say.
    @Test("a fold's line is answered from its key, like the row it stands over")
    func aFoldIsAnsweredFromItsKey() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        let fold = TranscriptEntryID.fold(41)
        heights.note(0, for: key("fold.41|shows-nothing"), measuredAt: 800)
        #expect(!fold.redrawsItself)
        #expect(!heights.needsMeasuring(key("fold.41|shows-nothing"), redrawsItself: fold.redrawsItself))
    }

    // MARK: - When a screenful is worth putting right

    /// **The blank under a fold's line, written down as the rule that missed it.** The repair ran
    /// on the table and the cache disagreeing, and a row nobody has measured at all is the two of
    /// them agreeing perfectly about the running mean. So the census counted the guess, printed it
    /// in debug builds, and did nothing about it.
    @Test("a visible row nobody has measured is worth putting right on its own")
    func aGuessIsWorthRepairing() {
        #expect(TranscriptRowHeights.needsRepair(guessed: 1, wrong: 0))
    }

    @Test("and so is the table disagreeing with the cache")
    func aDisagreementIsWorthRepairing() {
        #expect(TranscriptRowHeights.needsRepair(guessed: 0, wrong: 3))
    }

    /// A screen where every row has been measured and the table has been told is a screen to leave
    /// alone: the repair writes heights, which moves the document.
    @Test("a screen that is right is left alone")
    func aRightScreenIsLeftAlone() {
        #expect(!TranscriptRowHeights.needsRepair(guessed: 0, wrong: 0))
    }

    @Test("nothing is owed before a width has arrived, because nothing has been measured")
    func everythingIsOwedBeforeAWidth() {
        let heights = TranscriptRowHeights()
        #expect(heights.needsMeasuring(key("row.7"), redrawsItself: false))
    }

    // MARK: - Forgetting

    @Test("forgetting empties the cache and keeps the width")
    func forgets() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1, leading: 1.7)
        heights.note(120, for: key("row.7"), measuredAt: 800)
        heights.forget()
        #expect(heights.height(for: key("row.7")) == nil)
        #expect(heights.isReady)
        let invalidated = heights.reset(width: 800, scale: 1, leading: 1.7)
        #expect(!invalidated)
    }

    // MARK: - One estimate per KIND of row, not one per conversation

    /// **The reader's second report, written down: "still white gaps between output when I scroll
    /// up".** Scrolling back grows the window at the TOP, so the rows arriving are rows nobody has
    /// measured, and the number they were drawn at had settled from the screen the pane ARRIVED
    /// on, which is the live end and is the longest prose in the session. A screen of folded runs
    /// from an hour ago was then a screen of one line rows each given a paragraph's height, and a
    /// cell draws from its top down, so the difference is blank under every one of them.
    @Test("a head grow tells a fold what a fold is, not what the newest answer was")
    func aHeadGrowIsToldItsOwnShape() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        heights.showing(SessionID("chat"))
        // The arrival: three folds and a screenful of the answer the pane opened on.
        for fold in 0..<3 { heights.note(28, for: key("fold.\(fold)"), shape: .fold, measuredAt: 831) }
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(800, for: key("answer.\(row)"), shape: .answer, measuredAt: 831)
        }
        // The bound, doing its job: the middle of this sample is the 800 point answer, and no row
        // nobody has looked at may be told more than `mostEstimated`. See its own comment for why
        // guessing high is the expensive direction.
        #expect(heights.estimate == TranscriptRowHeights.mostEstimated)
        // The head grow: twelve folds nobody has measured, each of them truly 28 points.
        var blank = 0.0
        for fold in 3..<15 {
            blank += heights.assumed(for: key("fold.\(fold)"), shape: .fold) - 28
        }
        #expect(blank == 0)
        // What the same twelve rows were told before there were shapes. Eight thousand points of
        // blank, which is eight screens of it on a pane a thousand points tall.
        var wasBlank = 0.0
        for fold in 3..<15 {
            wasBlank += heights.assumed(for: key("fold.\(fold)")) - 28
        }
        // Five thousand points of blank, which is five screens of it. It was 8,106 before the
        // estimate was bounded, and both numbers are the same fault: a fold's line given a
        // paragraph's height because nothing had measured a fold.
        #expect(wasBlank == 5_064)
    }

    /// A shape with too little evidence is not a shape yet, and the honest answer for one is the
    /// number every row was told before there were shapes at all. Falling back rather than waiting
    /// for evidence: the fallback can only be as wrong as the old behaviour was.
    @Test("a shape nobody has measured enough of falls back to the conversation")
    func tooLittleOfAShapeFallsBack() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        for row in 0..<10 { heights.note(200, for: key("answer.\(row)"), shape: .answer, measuredAt: 831) }
        // Two is not enough to speak for a kind of row. See `settleShapeAfter`.
        heights.note(28, for: key("fold.1"), shape: .fold, measuredAt: 831)
        heights.note(28, for: key("fold.2"), shape: .fold, measuredAt: 831)
        // Ten answers and two folds, which is the conversation's own number and not a fold's.
        #expect(heights.estimate(for: .fold) == 200)
        // The third is.
        heights.note(28, for: key("fold.3"), shape: .fold, measuredAt: 831)
        #expect(heights.estimate(for: .fold) == 28)
    }

    /// The whole-conversation mean is still formed, and still from every row, because it is what a
    /// shape with nothing to say falls back to.
    @Test("a shape's rows still form the conversation's own mean")
    func shapesStillFeedTheWholeConversation() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        heights.note(100, for: key("a"), shape: .tool, measuredAt: 831)
        heights.note(300, for: key("b"), shape: .answer, measuredAt: 831)
        #expect(heights.estimate == 100)
    }

    /// **`.other` keeps no sample of its own**, because it is the shape for a row nothing has
    /// classified. A bucket for those would be a second whole-conversation mean settling on
    /// another schedule.
    @Test("an unclassified row is answered by the conversation's own mean")
    func otherIsTheConversation() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        for row in 0..<10 { heights.note(40, for: key("tool.\(row)"), shape: .tool, measuredAt: 831) }
        heights.note(900, for: key("tail"), shape: .other, measuredAt: 831)
        #expect(heights.estimate(for: .other) == heights.estimate)
        // And the unclassified row is in the conversation's sample like any other. A mean would
        // have answered 118 for a conversation of forty point rows, on the strength of the one
        // tall row in it.
        #expect(heights.estimate == 40)
    }

    /// A shape's number holds still for the reason the conversation's does: a table caches every
    /// height it is told, so a drifting estimate turns each wholesale re-ask into one jump.
    @Test("a shape's estimate settles and then holds still")
    func aShapeSettlesAndHolds() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.settleShapeAfter {
            heights.note(30, for: key("tool.\(row)"), shape: .tool, measuredAt: 831)
        }
        #expect(heights.estimate(for: .tool) == 30)
        // Two more, which is five drawn tool rows against the three it settled from. Not doubled,
        // so it holds however wrong it now is.
        heights.note(300, for: key("tool.wide.1"), shape: .tool, measuredAt: 831)
        heights.note(300, for: key("tool.wide.2"), shape: .tool, measuredAt: 831)
        #expect(heights.estimate(for: .tool) == 30)
    }

    /// An unlucky three is not permanent, which is what makes three a safe number to settle on.
    @Test("a shape's estimate is taken again once its sample has doubled and it is far out")
    func aShapeResettles() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        for row in 0..<3 { heights.note(300, for: key("tool.\(row)"), shape: .tool, measuredAt: 831) }
        #expect(heights.estimate(for: .tool) == 300)
        for row in 3..<6 { heights.note(30, for: key("tool.\(row)"), shape: .tool, measuredAt: 831) }
        // Six against the three it settled from, and half the sample says thirty. The mean this
        // used to take answered 165, which is a height no tool row in the sample has.
        #expect(heights.estimate(for: .tool) == 30)
    }

    /// A shape that is nearly right must not move, for the same reason the conversation's number
    /// must not: a wholesale re-ask cashes in whatever drift there has been.
    @Test("a shape that is nearly right is left alone")
    func aShapeDoesNotResettleForSmallDrift() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        for row in 0..<3 { heights.note(100, for: key("fold.\(row)"), shape: .fold, measuredAt: 831) }
        for row in 3..<40 { heights.note(105, for: key("fold.\(row)"), shape: .fold, measuredAt: 831) }
        #expect(heights.estimate(for: .fold) == 100)
    }

    /// The rows that drew nothing are not what forms a shape either, for the reason they are not
    /// what forms the conversation's number: they are answered rather than estimated.
    @Test("rows that drew nothing do not form a shape's estimate")
    func noughtsDoNotFormAShape() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        for row in 0..<50 { heights.note(0, for: key("blank.\(row)"), shape: .tool, measuredAt: 831) }
        for row in 0..<3 { heights.note(40, for: key("tool.\(row)"), shape: .tool, measuredAt: 831) }
        #expect(heights.estimate(for: .tool) == 40)
    }

    /// A row corrected after it was drawn is one contribution to its shape, not two. The streaming
    /// tail says itself on every frame of a turn, so this is the ordinary case rather than a
    /// corner of one.
    @Test("a row measured again does not count twice in its shape")
    func aShapeFollowsAnOverwrite() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        for row in 0..<2 { heights.note(40, for: key("tool.\(row)"), shape: .tool, measuredAt: 831) }
        heights.note(100, for: key("tool.0"), shape: .tool, measuredAt: 831)
        heights.note(40, for: key("tool.2"), shape: .tool, measuredAt: 831)
        // 100, 40 and 40, rather than 40, 40, 100 and 40, and the middle of those three is 40.
        #expect(heights.estimate(for: .tool) == 40)
    }

    /// A measured height belongs to a row and is kept for ever; every estimate formed from them
    /// belongs to the conversation and is not. The shapes go with the conversation's own number.
    @Test("pointing the pane elsewhere starts every shape again")
    func showingStartsEveryShapeAgain() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        heights.showing(SessionID("prose"))
        for row in 0..<3 { heights.note(900, for: key("answer.\(row)"), shape: .answer, measuredAt: 831) }
        // Nine hundred is what the sample says and `mostEstimated` is what an unmeasured row is
        // allowed to be told, which is the point of the bound: those three rows are drawn at 900
        // because they were measured, and the fourth is not.
        #expect(heights.estimate(for: .answer) == TranscriptRowHeights.mostEstimated)
        heights.showing(SessionID("tools"))
        #expect(heights.estimate(for: .answer) == TranscriptRowHeights.assumedRowHeight)
    }

    /// A resize keeps its numbers as estimates, so it keeps the shapes they make up. Emptying them
    /// would leave every row above the reader on `assumedRowHeight` for the length of a drag.
    @Test("a resize keeps the shapes as well as the heights")
    func shapesSurviveAResize() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        for row in 0..<3 { heights.note(30, for: key("tool.\(row)"), shape: .tool, measuredAt: 831) }
        heights.rewidth(to: 600)
        #expect(heights.estimate(for: .tool) == 30)
    }

    /// A text size change is not an estimate of anything, at any grouping.
    @Test("emptying the cache empties every shape")
    func forgettingEmptiesTheShapes() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 831, scale: 1, leading: 1.7)
        for row in 0..<3 { heights.note(30, for: key("tool.\(row)"), shape: .tool, measuredAt: 831) }
        heights.forget()
        #expect(heights.estimate(for: .tool) == TranscriptRowHeights.assumedRowHeight)
    }

    // MARK: - A height is a fact about a width

    /// **The two rows that emptied the owner's transcript**, from the one probe run of four that
    /// caught them. A three line paragraph whose height is 54 points reported 1,972, and a user
    /// message whose height is 444 reported 10,806, both only during a composer drag and both
    /// correct again afterwards. Both ratios are a row wrapped into a column about fifteen points
    /// wide: reports taken from a layout pass at a width the table was not.
    ///
    /// `reset` and `rewidth` have refused a width they cannot use since they were written. This is
    /// the same rule on the REPORTING path, which is the authoritative one.
    @Test("a height reported at another width is not news about this one")
    func aReportAtAnotherWidthIsRefused() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        heights.note(54, for: key("row.19554"), measuredAt: 420)
        // The spike, from a pass that laid the row out fifteen points wide.
        let took = heights.note(1_972, for: key("row.19554"), measuredAt: 15)
        #expect(!took)
        #expect(heights.height(for: key("row.19554")) == 54)
    }

    /// And the row that did the real damage: 444 points of user message reported as 10,806, which
    /// settled its shape's estimate at 6,025 and was then handed to every unmeasured row of that
    /// shape in a 2,650 row table.
    @Test("a spike from a narrow pass does not reach the estimate either")
    func aReportAtAnotherWidthDoesNotMoveTheEstimate() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        for row in 0..<3 {
            heights.note(444, for: key("message.\(row)"), shape: .message, measuredAt: 420)
        }
        #expect(heights.estimate(for: .message) == 444)
        heights.note(10_806, for: key("message.3"), shape: .message, measuredAt: 17)
        #expect(heights.estimate(for: .message) == 444)
        #expect(heights.assumed(for: key("message.unseen"), shape: .message) == 444)
    }

    /// A report at the width the cache is for is evidence, which is the ordinary case and the one
    /// everything else in this file depends on.
    @Test("a height reported at this width is news")
    func aReportAtThisWidthIsKept() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        let took = heights.note(120, for: key("row.7"), measuredAt: 420)
        #expect(took)
        #expect(heights.height(for: key("row.7")) == 120)
    }

    /// Half a point, the same tolerance a resize is judged by, because a clip view's own
    /// arithmetic lands on fractions and a row laid out at 419.75 is the same row.
    @Test("a fraction of a point is the same width")
    func aFractionIsTheSameWidth() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        let took = heights.note(120, for: key("row.7"), measuredAt: 419.75)
        #expect(took)
    }

    /// **Refusing costs a pass, not a measurement**, which is the whole reason this is safe. The
    /// row is laid out again at the right width and reports again, and that is the same mechanism
    /// that repairs every wrong height in this file today.
    @Test("a refused row is measured by the next report at the right width")
    func aRefusedRowIsMeasuredOnTheNextPass() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        heights.note(9_000, for: key("row.7"), measuredAt: 15)
        #expect(heights.height(for: key("row.7")) == nil)
        heights.note(120, for: key("row.7"), measuredAt: 420)
        #expect(heights.height(for: key("row.7")) == 120)
    }

    /// The rule on its own, without a cache, because the decision is what is being tested and a
    /// caller should be able to ask it.
    @Test("the rule, said on its own")
    func theEvidenceRule() {
        #expect(TranscriptRowHeights.isEvidence(measuredAt: 420, forCacheAt: 420))
        #expect(TranscriptRowHeights.isEvidence(measuredAt: 419.75, forCacheAt: 420))
        #expect(!TranscriptRowHeights.isEvidence(measuredAt: 15, forCacheAt: 420))
        #expect(!TranscriptRowHeights.isEvidence(measuredAt: 420, forCacheAt: 747))
        // A cache that is for no width at all cannot be told anything.
        #expect(!TranscriptRowHeights.isEvidence(measuredAt: 420, forCacheAt: nil))
    }

    // MARK: - The blank transcript, which is what a guess out by an order of magnitude looks like

    /// **The owner's own conversation, and the whole of why the estimate is not a mean.**
    ///
    /// `ComposerProbe` measured it: of 408 rows in one band, 26 had ever been measured at more
    /// than nothing, their mean was 651 points and their largest was 10,806. `settleShapeAfter`
    /// is three, so a sample of that shape settles a number for every unmeasured row of it. The
    /// mean of this sample is 3,635 points a row. The middle of it is 60.
    ///
    /// A row nobody has looked at, drawn 3,635 points tall, is eight screens of white with a line
    /// of text at the top. That is the transcript the reader filmed going blank.
    @Test("one enormous row does not decide what every other row is")
    func aTailDoesNotDecideTheEstimate() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        heights.showing(SessionID("his"))
        heights.note(40, for: key("answer.1"), shape: .answer, measuredAt: 420)
        heights.note(60, for: key("answer.2"), shape: .answer, measuredAt: 420)
        heights.note(10_806, for: key("answer.3"), shape: .answer, measuredAt: 420)
        #expect(heights.estimate(for: .answer) == 60)
        #expect(heights.assumed(for: key("answer.unseen"), shape: .answer) == 60)
        // And the row that really is ten thousand points tall is still ten thousand points tall.
        #expect(heights.assumed(for: key("answer.3"), shape: .answer) == 10_806)
    }

    /// **What that costs a document, which is the number the reader actually feels.**
    ///
    /// The 2,242 rows above the band in the probe run, none of them measured. A mean over the
    /// sample above hands them over eight million points. The middle hands them 134,520. The
    /// truth, once every one of them had been measured, was 145,686.
    @Test("the rows nobody has measured do not add up to a document of fiction")
    func aDocumentOfEstimatesIsNotFiction() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        heights.showing(SessionID("his"))
        heights.note(40, for: key("answer.1"), shape: .answer, measuredAt: 420)
        heights.note(60, for: key("answer.2"), shape: .answer, measuredAt: 420)
        heights.note(10_806, for: key("answer.3"), shape: .answer, measuredAt: 420)
        var document = 0.0
        for row in 0..<2_242 {
            document += heights.assumed(for: key("above.\(row)"), shape: .answer)
        }
        #expect(document == 134_520)
    }

    // MARK: - What a row nobody has looked at may be told

    /// **The bound, and the asymmetry behind it.** Guessing low costs a row that grows when it is
    /// drawn, which is the design already. Guessing high costs a screenful of white a reader
    /// cannot tell from a broken app, and that they cannot scroll out of, because the next screen
    /// is more of the same row. See `mostEstimated`.
    @Test("no row nobody has looked at may fill the screen on its own")
    func theGuessIsBounded() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(6_025, for: key("answer.\(row)"), shape: .answer, measuredAt: 420)
        }
        #expect(heights.estimate == TranscriptRowHeights.mostEstimated)
        #expect(heights.estimate(for: .answer) == TranscriptRowHeights.mostEstimated)
        #expect(
            heights.assumed(for: key("unseen"), shape: .answer)
                == TranscriptRowHeights.mostEstimated
        )
    }

    /// The bound is on the GUESS and never on a measurement. A row that has been measured at six
    /// thousand points is drawn at six thousand points, because that is what it is.
    @Test("a measured row is its own height however tall it is")
    func theBoundIsOnlyOnTheGuess() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        heights.note(6_025, for: key("answer.1"), shape: .answer, measuredAt: 420)
        #expect(heights.height(for: key("answer.1")) == 6_025)
        #expect(heights.assumed(for: key("answer.1"), shape: .answer) == 6_025)
    }

    /// A conversation whose rows are genuinely short is not pushed up to the bound. It is a
    /// ceiling rather than a number.
    @Test("the bound does not touch an estimate that is already sensible")
    func theBoundLeavesASensibleEstimateAlone() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 420, scale: 1, leading: 1.7)
        for row in 0..<TranscriptRowHeights.settleAfter {
            heights.note(24, for: key("row.\(row)"), measuredAt: 420)
        }
        #expect(heights.estimate == 24)
    }
}
