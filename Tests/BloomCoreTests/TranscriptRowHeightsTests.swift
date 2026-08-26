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
        #expect(heights.reset(width: 600, scale: 1))
        #expect(heights.height(for: "row.7") == nil)
        #expect(heights.count == 0)
    }

    @Test("a change of text size empties the cache")
    func scaleInvalidates() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        heights.note(120, for: "row.7")
        #expect(heights.reset(width: 800, scale: 1.3))
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
        #expect(!heights.reset(width: 831.75, scale: 1))
        #expect(heights.height(for: "row.7") == 120)
    }

    @Test("a pass that changes nothing says so")
    func noChangeIsNotAnInvalidation() {
        var heights = TranscriptRowHeights()
        #expect(heights.reset(width: 800, scale: 1))
        #expect(!heights.reset(width: 800, scale: 1))
    }

    // MARK: - The width that has not arrived yet

    /// A table that has not been laid out reports a width of nought or one, and a row measured
    /// against that is a row one point tall. A table told one point per row is a transcript that is
    /// not there.
    @Test("a width nothing can be drawn at is not a width")
    func refusesAnUnlaidPane() {
        var heights = TranscriptRowHeights()
        #expect(!heights.reset(width: 0, scale: 1))
        #expect(!heights.reset(width: 1, scale: 1))
        #expect(!heights.isReady)
    }

    @Test("nothing is remembered before a width has arrived")
    func refusesHeightsWithoutAWidth() {
        var heights = TranscriptRowHeights()
        #expect(!heights.note(120, for: "row.7"))
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
        #expect(heights.note(340, for: "row.7"))
        #expect(heights.height(for: "row.7") == 340)
    }

    /// A row reports its size on every layout pass. Telling the table to relayout on every one of
    /// those is a transcript that never stops working.
    @Test("a height that has not moved is not news")
    func ignoresAnUnchangedHeight() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        #expect(heights.note(120, for: "row.7"))
        #expect(!heights.note(120, for: "row.7"))
        // Rounds up to the same 120, so a fraction of a point of drift says nothing either.
        #expect(!heights.note(119.6, for: "row.7"))
    }

    /// This was the several hundred points of blank between the rows of a real conversation: an
    /// empty row drew nothing, said so, and was told it did not count. See the header.
    @Test("nought is a real height and is kept")
    func nothingIsAnAnswer() {
        var heights = TranscriptRowHeights()
        heights.reset(width: 800, scale: 1)
        #expect(heights.note(0, for: "row.7"))
        #expect(heights.height(for: "row.7") == 0)
    }

    @Test("a height is rounded up, and never below nothing")
    func rounds() {
        #expect(TranscriptRowHeights.rounded(23.1) == 24)
        #expect(TranscriptRowHeights.rounded(24) == 24)
        #expect(TranscriptRowHeights.rounded(-3) == 0)
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
        #expect(!heights.reset(width: 800, scale: 1))
    }
}
