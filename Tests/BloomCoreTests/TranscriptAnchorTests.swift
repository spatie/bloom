import Testing
import Foundation
@testable import BloomCore

@Suite("Keeping a transcript reader still")
struct TranscriptAnchorTests {
    // MARK: - The row the reader was on

    /// The bug this whole mechanism exists for: `TranscriptWindow.grownUp` puts four hundred rows
    /// in above the viewport, and a reader put back to the same POINT is thrown backwards through
    /// the conversation by exactly what was added. Put back on the same ROW they do not move at
    /// all, however much went in above.
    @Test("rows put in above the reader do not move the reader")
    func historyAboveTheReaderMovesNothing() {
        // The reader is 40 points into the row at the top of the pane.
        let delta = TranscriptAnchor.delta(rowTop: 8_000, viewportTop: 8_040)
        #expect(delta == -40)
        // 12,000 points of history goes in above it, so the same row is now further down.
        let restored = TranscriptAnchor.offset(rowTop: 20_000, delta: delta)
        #expect(restored == 20_040)
    }

    @Test("a row exactly at the top of the pane comes back exactly there")
    func flushWithTheTop() {
        let delta = TranscriptAnchor.delta(rowTop: 8_000, viewportTop: 8_000)
        #expect(TranscriptAnchor.offset(rowTop: 500, delta: delta) == 500)
    }

    /// Growth in the other direction: the window moved to the tail and dropped the history above,
    /// so the anchored row is nearer the top of the document than it was.
    @Test("rows taken from above the reader do not move the reader either")
    func historyRemovedMovesNothing() {
        let delta = TranscriptAnchor.delta(rowTop: 20_000, viewportTop: 20_120)
        #expect(TranscriptAnchor.offset(rowTop: 300, delta: delta) == 420)
    }

    @Test("the round trip is the identity whatever the row moved by")
    func roundTrip() {
        for move in [-9_000.0, -1, 0, 1, 12_345] {
            let rowTop = 4_000.0
            let delta = TranscriptAnchor.delta(rowTop: rowTop, viewportTop: 4_017)
            #expect(TranscriptAnchor.offset(rowTop: rowTop + move, delta: delta) == 4_017 + move)
        }
    }

    // MARK: - Where the end is

    /// **The only number that means the end.** A row being visible is not it: the last row of a
    /// transcript is often taller than the pane, so a scroll that stops when its top comes into
    /// view leaves the rest of it below the fold.
    @Test("the end of the content is the content less the pane")
    func end() {
        #expect(TranscriptAnchor.end(contentHeight: 20_000, viewportHeight: 800) == 19_200)
    }

    /// A conversation shorter than the pane has no end below the reader to go to, and a pane that
    /// has not been laid out has no height at all. Both would give a negative end, which as a
    /// scroll offset is above the top of the document.
    @Test("content that fits has nowhere to go")
    func endOfShortContent() {
        #expect(TranscriptAnchor.end(contentHeight: 300, viewportHeight: 800) == 0)
        #expect(TranscriptAnchor.end(contentHeight: 300, viewportHeight: 0) == 300)
        #expect(TranscriptAnchor.end(contentHeight: 0, viewportHeight: 0) == 0)
    }

    @Test("a wanted offset is brought inside the range")
    func clamps() {
        #expect(TranscriptAnchor.clamped(-500, contentHeight: 20_000, viewportHeight: 800) == 0)
        #expect(
            TranscriptAnchor.clamped(1_000_000, contentHeight: 20_000, viewportHeight: 800)
                == 19_200
        )
        #expect(TranscriptAnchor.clamped(5_000, contentHeight: 20_000, viewportHeight: 800) == 5_000)
    }

    /// Naming a number past the end is how every "go to the newest row" in the transcript is said,
    /// so that no caller has to know the document height to mean the end.
    @Test("asking for past the end is asking for the end")
    func pastTheEndIsTheEnd() {
        let end = TranscriptAnchor.end(contentHeight: 20_000, viewportHeight: 800)
        #expect(
            TranscriptAnchor.clamped(20_000, contentHeight: 20_000, viewportHeight: 800) == end
        )
    }

    // MARK: - Putting a row somewhere in the pane

    @Test("a row at the top of the pane")
    func rowAtTheTop() {
        let y = TranscriptAnchor.offset(
            rowTop: 5_000, rowHeight: 120, viewportHeight: 800, anchor: 0
        )
        #expect(y == 5_000)
    }

    /// What a search result gets, because the sentence usually needs the turn around it to make
    /// sense.
    @Test("a row centred in the pane")
    func rowCentred() {
        let y = TranscriptAnchor.offset(
            rowTop: 5_000, rowHeight: 120, viewportHeight: 800, anchor: 0.5
        )
        #expect(y == 5_000 + 60 - 400)
    }

    /// What the setup log's reveal asks for: the end of the log against the bottom of the pane.
    @Test("a row against the bottom of the pane")
    func rowAtTheBottom() {
        let y = TranscriptAnchor.offset(
            rowTop: 5_000, rowHeight: 120, viewportHeight: 800, anchor: 1
        )
        #expect(y == 5_120 - 800)
    }

    /// A row near the top of a conversation resolves above the document, and a row near the end
    /// resolves past it. That is on purpose: this says where the row wants to be and the caller
    /// clamps, because only the caller knows the content height.
    @Test("a row near either end resolves outside the range and is clamped by the caller")
    func rowNearTheEdges() {
        let high = TranscriptAnchor.offset(
            rowTop: 10, rowHeight: 40, viewportHeight: 800, anchor: 0.5
        )
        #expect(high < 0)
        #expect(TranscriptAnchor.clamped(high, contentHeight: 20_000, viewportHeight: 800) == 0)
    }

    // MARK: - Whether the instruction to be at the end survived

    /// **Exact, and deliberately not `ScrollEnd.isAtEnd`.** That one is about whether a reader is
    /// still following along and allows them a line or two of slack. This is about whether the
    /// jump pill did what it was pressed for, and ninety points short of the newest row is short.
    @Test("nearly at the end is not at the end")
    func nearlyIsNotAtIt() {
        #expect(TranscriptAnchor.isAtEnd(offset: 19_200, contentHeight: 20_000, viewportHeight: 800))
        #expect(!TranscriptAnchor.isAtEnd(offset: 19_110, contentHeight: 20_000, viewportHeight: 800))
        // And the same position is "following along" to an arriving row, which is the whole point
        // of the two questions being different. Ninety points short, so it is inside ScrollEnd's
        // 96 and well outside the one point of slack above.
        #expect(
            ScrollEnd.isAtEnd(contentHeight: 20_000, viewportHeight: 800, offset: 19_110)
        )
    }

    /// A clip view's own arithmetic lands on fractions, and the transcript must not chase a
    /// quarter of a point for ever.
    @Test("a fraction of a point still counts as the end")
    func aFractionIsStillTheEnd() {
        #expect(
            TranscriptAnchor.isAtEnd(offset: 19_199.4, contentHeight: 20_000, viewportHeight: 800)
        )
    }

    @Test("past the end counts as the end")
    func pastTheEnd() {
        #expect(TranscriptAnchor.isAtEnd(offset: 19_500, contentHeight: 20_000, viewportHeight: 800))
    }

    @Test("content that fits is at its end wherever the offset says")
    func shortContentIsAtItsEnd() {
        #expect(TranscriptAnchor.isAtEnd(offset: 0, contentHeight: 300, viewportHeight: 800))
    }
}
