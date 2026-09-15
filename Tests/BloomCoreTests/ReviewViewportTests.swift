import Testing
@testable import BloomCore

@Suite("Drawing the review's diff blocks near the reader")
struct ReviewViewportTests {
    /// The measured failure: a block spanning the whole visible rect, which the old scroll-relative
    /// frame placed a viewport and more below and so never drew.
    @Test("a block spanning the visible rect is near")
    func spanningBlock() {
        #expect(ReviewViewport.isNear(top: 11_352, bottom: 16_092, visibleTop: 13_183, visibleHeight: 600))
    }

    @Test("a block starts drawing half a viewport above the top")
    func leadAbove() {
        #expect(ReviewViewport.isNear(top: 500, bottom: 701, visibleTop: 1_000, visibleHeight: 600))
        #expect(!ReviewViewport.isNear(top: 500, bottom: 700, visibleTop: 1_000, visibleHeight: 600))
    }

    @Test("a block starts drawing a viewport and a half below the top")
    func leadBelow() {
        #expect(ReviewViewport.isNear(top: 1_899, bottom: 2_400, visibleTop: 1_000, visibleHeight: 600))
        #expect(!ReviewViewport.isNear(top: 1_900, bottom: 2_400, visibleTop: 1_000, visibleHeight: 600))
    }

    @Test("the published top moves in quarter viewport steps")
    func quarterSteps() {
        #expect(ReviewViewport.publishedTop(visibleTop: 0, visibleHeight: 600) == 0)
        #expect(ReviewViewport.publishedTop(visibleTop: 74, visibleHeight: 600) == 0)
        #expect(ReviewViewport.publishedTop(visibleTop: 76, visibleHeight: 600) == 150)
        #expect(ReviewViewport.publishedTop(visibleTop: 13_183, visibleHeight: 600) == 13_200)
    }

    /// The rounding must never hide a block the reader can actually see, wherever the offset sits
    /// between two steps.
    @Test("anything on screen is near at the published top")
    func roundingKeepsVisibleBlocksNear() {
        let height = 600.0
        for visibleTop in stride(from: 0.0, through: 3_000, by: 7) {
            let published = ReviewViewport.publishedTop(visibleTop: visibleTop, visibleHeight: height)
            // A thin block at the very top and at the very bottom of what is visible.
            #expect(ReviewViewport.isNear(top: visibleTop, bottom: visibleTop + 1, visibleTop: published, visibleHeight: height))
            #expect(ReviewViewport.isNear(top: visibleTop + height - 1, bottom: visibleTop + height,
                                          visibleTop: published, visibleHeight: height))
        }
    }

    @Test("a pane with no height publishes its offset unchanged")
    func unlaidPane() {
        #expect(ReviewViewport.publishedTop(visibleTop: 42, visibleHeight: 0) == 42)
    }
}
