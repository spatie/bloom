import Testing
@testable import BloomCore

/// The three answers a delayed wait has to get right, and the third one is the one that comes back
/// as a bug report: a spinner that appears for two frames on a switch that was already finished.
@Suite("When a wait is worth saying so")
struct SlowWaitTests {
    @Test("nothing at all before the threshold")
    func silentUntilTheThreshold() {
        #expect(!SlowWait.isShowing(waited: .zero))
        #expect(!SlowWait.isShowing(waited: .milliseconds(1)))
        #expect(!SlowWait.isShowing(waited: SlowWait.threshold - .milliseconds(1)))
    }

    @Test("something once the threshold has passed")
    func showsOnceTheThresholdPasses() {
        #expect(SlowWait.isShowing(waited: SlowWait.threshold))
        #expect(SlowWait.isShowing(waited: SlowWait.threshold + .milliseconds(1)))
        #expect(SlowWait.isShowing(waited: .seconds(30)))
    }

    /// The flicker arriving by the other route. A pane that measured the wait and only then found
    /// the content had landed must draw nothing, however long the wait ran.
    @Test("a wait that has already ended says nothing, however long it ran")
    func aFinishedWaitSaysNothing() {
        #expect(!SlowWait.isShowing(waited: .seconds(30), isOver: true))
        #expect(!SlowWait.isShowing(waited: SlowWait.threshold, isOver: true))
        #expect(!SlowWait.isShowing(waited: .zero, isOver: true))
    }

    @Test("the threshold can be moved without moving the rule")
    func theThresholdIsAParameter() {
        #expect(SlowWait.isShowing(waited: .milliseconds(100), threshold: .milliseconds(50)))
        #expect(!SlowWait.isShowing(waited: .milliseconds(100), threshold: .seconds(2)))
    }

    /// One sleep for the remainder, rather than a tick that wakes to ask a question it could have
    /// worked out for itself.
    @Test("the quiet is exactly what is left of the threshold")
    func quietIsTheRemainder() {
        #expect(SlowWait.quiet() == SlowWait.threshold)
        #expect(SlowWait.quiet(after: .milliseconds(200)) == SlowWait.threshold - .milliseconds(200))
    }

    @Test("there is nothing left to stay quiet for once the threshold is reached")
    func quietEndsAtTheThreshold() {
        #expect(SlowWait.quiet(after: SlowWait.threshold) == nil)
        #expect(SlowWait.quiet(after: .seconds(10)) == nil)
    }

    /// The two halves have to meet: the moment the quiet runs out is the moment the wait shows.
    /// Written as a walk rather than as one assertion about `threshold`, so a future rule that
    /// stays quiet in more than one stretch is still held to the same join.
    @Test("the quiet ends exactly where the spinner starts")
    func thePairMeet() {
        var waited = Duration.zero
        while let quiet = SlowWait.quiet(after: waited) {
            #expect(!SlowWait.isShowing(waited: waited))
            waited += quiet
        }
        #expect(SlowWait.isShowing(waited: waited))
    }
}
