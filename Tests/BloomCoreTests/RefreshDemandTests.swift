import Testing
@testable import BloomCore

@Suite("Refresh demand")
struct RefreshDemandTests {
    @Test("the first request starts a run")
    func firstRequestStarts() {
        var demand = RefreshDemand()

        let started = demand.request()
        #expect(started)
        #expect(demand.isRunning)
        let repeats = demand.complete()
        #expect(!repeats)
        #expect(!demand.isRunning)
    }

    @Test("a burst during a run asks for one final refresh")
    func burstEndsFresh() {
        var demand = RefreshDemand()

        let started = demand.request()
        #expect(started)
        for _ in 0 ..< 8 {
            let startsAnother = demand.request()
            #expect(!startsAnother)
        }

        let repeats = demand.complete()
        #expect(repeats)
        #expect(demand.isRunning)
        let repeatsAgain = demand.complete()
        #expect(!repeatsAgain)
        #expect(!demand.isRunning)
    }

    @Test("requests during the final refresh are retained too")
    func finalRefreshCanBeFollowed() {
        var demand = RefreshDemand()

        let started = demand.request()
        let startsParallel = demand.request()
        let repeats = demand.complete()
        let startsDuringRepeat = demand.request()
        let repeatsAgain = demand.complete()
        let finishes = demand.complete()

        #expect(started)
        #expect(!startsParallel)
        #expect(repeats)
        #expect(!startsDuringRepeat)
        #expect(repeatsAgain)
        #expect(!finishes)
    }
}
