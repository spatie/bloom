import Testing
@testable import BloomCore

@Suite("Explicit transcript scrolling")
struct TranscriptLiveEndRequestTests {
    @Test func waitsForThePaneToArrive() {
        var request = TranscriptLiveEndRequest()
        let early = request.consume(1, isReady: false)
        #expect(!early)
        #expect(request.handled == 0)
        let arrived = request.consume(1, isReady: true)
        #expect(arrived)
        #expect(request.handled == 1)
    }

    @Test func replaysRequestsSentWhileThePaneWasAbsentOnlyOnce() {
        var request = TranscriptLiveEndRequest(handled: 2)
        let returning = request.consume(4, isReady: true)
        let repeated = request.consume(4, isReady: true)
        #expect(returning)
        #expect(!repeated)
        #expect(request.handled == 4)
    }

    @Test func returningWithoutANewRequestPreservesTheReadersPlace() {
        var request = TranscriptLiveEndRequest(handled: 2)
        let returning = request.consume(2, isReady: true)
        #expect(!returning)
    }

    @Test func eachPaneAcknowledgesRequestsIndependently() {
        var first = TranscriptLiveEndRequest()
        var second = TranscriptLiveEndRequest()
        let visible = first.consume(1, isReady: true)
        let hidden = second.consume(1, isReady: false)
        let returning = second.consume(1, isReady: true)
        #expect(visible)
        #expect(!hidden)
        #expect(returning)
    }
}
