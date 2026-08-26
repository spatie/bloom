import Testing
import Foundation
@testable import BloomCore

@Suite("What the transcript animates")
struct TranscriptMotionTests {
    @Test("a row that lands where something else was fades in")
    func rowsThatFade() {
        #expect(TranscriptMotion.fadesOnArrival(.toolUse))
        #expect(TranscriptMotion.fadesOnArrival(.toolResult))
        #expect(TranscriptMotion.fadesOnArrival(.permissionAsk))
        #expect(TranscriptMotion.fadesOnArrival(.result))
        #expect(TranscriptMotion.fadesOnArrival(.error))
        #expect(TranscriptMotion.fadesOnArrival(.system))
        #expect(TranscriptMotion.fadesOnArrival(.notice))
    }

    /// All three are already on screen when the stored row lands, drawn by something lined up
    /// column for column with it. A fade would take what the reader is looking at away and bring
    /// it back.
    @Test("a row that replaces something already drawn does not")
    func rowsThatDoNotFade() {
        #expect(!TranscriptMotion.fadesOnArrival(.assistantText))
        #expect(!TranscriptMotion.fadesOnArrival(.thinking))
        #expect(!TranscriptMotion.fadesOnArrival(.user))
    }

    // MARK: Going back to the live end

    @Test("Reduce Motion is taken there instantly")
    func reduceMotionJumps() {
        #expect(TranscriptMotion.liveEndMove(distance: 5000, reduceMotion: true) == .jump)
        #expect(TranscriptMotion.liveEndMove(distance: 200, reduceMotion: true) == .jump)
    }

    /// The pill is only offered while the reader is away from the end, but the distance is read
    /// off a quantised measurement that can be a scroll behind, and a jump to where you already
    /// are should not be a curve.
    @Test("a reader who is already at the end is not taken on a journey")
    func nowhereToGo() {
        #expect(TranscriptMotion.liveEndMove(distance: 0, reduceMotion: false) == .jump)
        #expect(TranscriptMotion.liveEndMove(distance: -40, reduceMotion: false) == .jump)
        #expect(TranscriptMotion.liveEndMove(distance: 95, reduceMotion: false) == .jump)
    }

    /// The whole of the argument on `glideCeiling`: a hundredfold change in distance buys a
    /// tenth of a second. Written as a ratio rather than as two literals so that moving the floor
    /// or the ceiling has to keep the shape rather than only the numbers.
    @Test("the glide is nearly the same length however far it has to go")
    func nearlyConstantDuration() {
        let near = seconds(TranscriptMotion.liveEndMove(distance: 200, reduceMotion: false))
        let far = seconds(TranscriptMotion.liveEndMove(distance: 20_000, reduceMotion: false))

        #expect(near > 0)
        #expect(far > near)
        // A hundredfold in distance, less than double in time.
        #expect(far / near < 2)
        // And the long one is still short enough to read as a movement rather than an effect.
        #expect(far <= 0.3)
    }

    @Test("the glide never runs past its ceiling or under its floor")
    func bounded() {
        for distance in stride(from: 96.0, through: 40_000, by: 137) {
            let length = seconds(TranscriptMotion.liveEndMove(distance: distance, reduceMotion: false))
            #expect(length >= TranscriptMotion.glideFloor)
            #expect(length <= TranscriptMotion.glideCeiling)
        }
    }

    @Test("past the ramp the answer stops moving")
    func saturates() {
        let atRamp = TranscriptMotion.liveEndMove(distance: TranscriptMotion.glideRamp, reduceMotion: false)
        let farPast = TranscriptMotion.liveEndMove(distance: TranscriptMotion.glideRamp * 30, reduceMotion: false)
        #expect(atRamp == farPast)
        #expect(atRamp == .glide(seconds: TranscriptMotion.glideCeiling))
    }

    private func seconds(_ move: TranscriptMotion.LiveEndMove) -> Double {
        switch move {
        case .jump: 0
        case .glide(let seconds): seconds
        }
    }

    // MARK: - Settling onto the screen

    /// Shape rather than literals: what matters is that there is travel under the opacity and
    /// that the whole thing is over quickly. Opacity alone was filmed and measured at a thirtieth
    /// the weight of an ordinary stream delta landing beside it, which is why a rise of zero is
    /// the one value this must never come back to.
    @Test("a settle has both a length and some travel, and neither is an effect")
    func settleShape() throws {
        let settle = try #require(TranscriptMotion.arrival(reduceMotion: false))
        #expect(settle.rise > 0)
        #expect(settle.rise < 12)
        #expect(settle.seconds > 0.1)
        #expect(settle.seconds < 0.4)
    }

    /// Dropped rather than slowed, like every other call site in the app, and absent rather than
    /// zeroed so that a caller cannot honour half of it and leave a row hidden.
    @Test("Reduce Motion is owed no settle at all")
    func settleUnderReduceMotion() {
        #expect(TranscriptMotion.arrival(reduceMotion: true) == nil)
    }
}
