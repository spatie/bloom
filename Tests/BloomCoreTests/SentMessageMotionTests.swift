import Testing
@testable import BloomCore

struct SentMessageMotionTests {
    @Test func shortConversationStartsBehindTheComposer() {
        #expect(SentMessageMotion.distance(rowTop: 120, viewportBottom: 800, composerClearance: 100) == 580)
    }

    @Test func scrollingConversationDoesNotGetASecondLift() {
        #expect(SentMessageMotion.distance(rowTop: 1_500, viewportBottom: 1_600, composerClearance: 100) == 0)
        #expect(SentMessageMotion.distance(rowTop: 1_540, viewportBottom: 1_600, composerClearance: 100) == 0)
    }

    @Test func composerHeightMovesTheStartingEdge() {
        #expect(SentMessageMotion.distance(rowTop: 480, viewportBottom: 800, composerClearance: 200) == 120)
    }
}
