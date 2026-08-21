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
