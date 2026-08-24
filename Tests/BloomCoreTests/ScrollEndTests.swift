import Testing
import Foundation
@testable import BloomCore

@Suite("Being at the end of a scroll")
struct ScrollEndTests {
    /// The state the owner photographed: a finished turn, its last line fully on screen, and a
    /// stretch of empty pane between it and the composer. There is nothing below to jump to
    /// because there is nothing below at all.
    @Test("content that fits in the pane is at its end, wherever the offset says it is")
    func contentShorterThanTheViewport() {
        #expect(ScrollEnd.isAtEnd(contentHeight: 400, viewportHeight: 820, offset: 0))
        // A top content inset makes the resting offset negative, which the subtraction alone
        // would read as being further from the end rather than nearer it.
        #expect(ScrollEnd.isAtEnd(contentHeight: 400, viewportHeight: 820, offset: -52))
        // And right up against the viewport's own height, which is the boundary.
        #expect(ScrollEnd.isAtEnd(contentHeight: 820, viewportHeight: 820, offset: 0))
    }

    /// A pane that is not the tab on screen, the frame a window opens on, a split divider dragged
    /// to the floor. Every one of those measures as a full height of content in no viewport, and
    /// the subtraction reads it as a reader a long way from the end of a pane they cannot see.
    @Test("a pane with no height has not been scrolled away from")
    func viewportWithNoHeight() {
        #expect(ScrollEnd.isAtEnd(contentHeight: 4000, viewportHeight: 0, offset: 0))
        #expect(ScrollEnd.isAtEnd(contentHeight: 4000, viewportHeight: -1, offset: 0))
    }

    @Test("content taller than the pane is at its end only near the bottom of it")
    func contentTallerThanTheViewport() {
        // Sitting exactly at the bottom.
        #expect(ScrollEnd.isAtEnd(contentHeight: 4000, viewportHeight: 800, offset: 3200))
        // A nudge of the wheel is still following along.
        #expect(ScrollEnd.isAtEnd(contentHeight: 4000, viewportHeight: 800, offset: 3150))
        // Half a pane up is not.
        #expect(!ScrollEnd.isAtEnd(contentHeight: 4000, viewportHeight: 800, offset: 2800))
        // And the top of a long session certainly is not.
        #expect(!ScrollEnd.isAtEnd(contentHeight: 4000, viewportHeight: 800, offset: 0))
    }

    @Test("the threshold is where it says it is")
    func thresholdBoundary() {
        let content = 4000.0, viewport = 800.0
        let atEnd = content - viewport
        #expect(ScrollEnd.isAtEnd(
            contentHeight: content, viewportHeight: viewport, offset: atEnd - 95
        ))
        #expect(!ScrollEnd.isAtEnd(
            contentHeight: content, viewportHeight: viewport, offset: atEnd - 96
        ))
    }

    /// Queued messages are drawn under the last completed turn, so they make the content taller.
    /// Whatever decides "there is more below" has to be right for them too, or the pill comes back
    /// wrong in a new way.
    @Test("a queued message that fits in the pane does not put the reader away from the end")
    func pendingBubblesDoNotMoveTheEnd() {
        // A short conversation, plus two pending bubbles, still inside the pane.
        #expect(ScrollEnd.isAtEnd(contentHeight: 500, viewportHeight: 820, offset: 0))
        // And once they push it past the pane, the reader at the top of it genuinely is away.
        #expect(!ScrollEnd.isAtEnd(contentHeight: 1200, viewportHeight: 820, offset: 0))
    }
}

/// When an offer to go back to the newest row is worth drawing.
///
/// The pill read `isAtEnd`, which answers a different question: whether the reader is still
/// following along, which decides whether an arriving row may move the view. That one is small on
/// purpose, so the pill appeared after a line and a half of scrolling, over a conversation whose
/// newest row was still on screen.
@Suite("Offering the way back")
struct ScrollEndOfferTests {
    private func offers(offset: Double, content: Double = 4_000, viewport: Double = 800) -> Bool {
        ScrollEnd.isWorthOffering(
            contentHeight: content, viewportHeight: viewport, offset: offset
        )
    }

    /// The complaint: a nudge of the wheel is not leaving the conversation.
    @Test("a line or two of scrolling is not worth an offer")
    func aNudgeOffersNothing() {
        // At the very end, and 96 points up, which is what `isAtEnd` still calls "following".
        #expect(!offers(offset: 3_200))
        #expect(!offers(offset: 3_104))
    }

    /// Far enough that the end is somewhere the reader cannot see and would have to work to get
    /// back to.
    @Test("a screen and a half away is")
    func screensAwayOffers() {
        // 3_200 is the end. A screen and a half is 1_200 points of gap.
        #expect(!offers(offset: 2_100))
        #expect(offers(offset: 1_900))
        #expect(offers(offset: 0))
    }

    /// Screens rather than points, so the same gesture means the same thing on a tall window and
    /// a short one.
    @Test("the distance is measured in screens, not points")
    func theDistanceScalesWithTheWindow() {
        // 900 points of gap: over a screen and a half on a short pane, under it on a tall one.
        #expect(offers(offset: 2_300, content: 4_000, viewport: 500) == true)
        #expect(offers(offset: 2_300, content: 4_000, viewport: 800) == false)
    }

    /// The same guards `isAtEnd` has, and for the same reason: a reader can only be away from an
    /// end that is below them.
    @Test("a pane with nothing to scroll never offers")
    func nothingToScrollOffersNothing() {
        #expect(!ScrollEnd.isWorthOffering(contentHeight: 4_000, viewportHeight: 0, offset: 0))
        #expect(!ScrollEnd.isWorthOffering(contentHeight: 300, viewportHeight: 800, offset: 0))
    }

    /// It is not the negation of the other question, and must not become one.
    @Test("still following along and worth offering are different answers")
    func theTwoQuestionsDisagreeOnPurpose() {
        // Half a screen up: no longer pinned to the end, and not yet worth a pill.
        let content = 4_000.0, viewport = 800.0, offset = 2_800.0
        #expect(!ScrollEnd.isAtEnd(
            contentHeight: content, viewportHeight: viewport, offset: offset
        ))
        #expect(!ScrollEnd.isWorthOffering(
            contentHeight: content, viewportHeight: viewport, offset: offset
        ))
    }
}
