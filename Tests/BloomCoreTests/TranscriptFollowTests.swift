import Testing
import Foundation
@testable import BloomCore

@Suite("Following the live end")
struct TranscriptFollowTests {
    // MARK: - Who this is allowed to move

    /// The whole safety of the mechanism. A reader further from the end than the pill's own
    /// threshold is reading something, and nothing here may touch them however much arrives.
    @Test("a reader who has scrolled up is never moved")
    func leavesAReaderAlone() {
        let end = 10_000.0
        for gap in [ScrollEnd.threshold + 1, 200, 3_000, 9_000] {
            let move = TranscriptFollow.step(
                offset: end - gap, end: end, frame: 1 / 60, ownsGap: false
            )
            #expect(move == .rest)
        }
    }

    @Test("a reader who has scrolled up keeps their place when content lands")
    func doesNotTakeBackFromAReader() {
        let offset = TranscriptFollow.start(offset: 5_000, end: 10_000, grew: 60, ownsGap: false)
        #expect(offset == 5_000)
    }

    @Test("a view already at the end has nothing to do")
    func restsAtTheEnd() {
        #expect(TranscriptFollow.step(offset: 10_000, end: 10_000, frame: 1 / 60, ownsGap: false) == .rest)
        #expect(TranscriptFollow.step(offset: 9_999.8, end: 10_000, frame: 1 / 60, ownsGap: false) == .rest)
    }

    /// A row folding up, or a streamed block replaced by a shorter stored one. There is nothing
    /// to watch about travelling backwards.
    @Test("content that shrinks under the view is put right at once")
    func snapsBackFromBeyondTheEnd() {
        let move = TranscriptFollow.step(
            offset: 10_400, end: 10_000, frame: 1 / 60, ownsGap: false
        )
        #expect(move == .settle(10_000))
    }

    @Test("a pane with nothing to scroll is left alone")
    func nothingToScroll() {
        #expect(TranscriptFollow.step(offset: 0, end: 0, frame: 1 / 60, ownsGap: false) == .rest)
        #expect(TranscriptFollow.start(offset: 0, end: 0, grew: 60, ownsGap: false) == 0)
    }

    /// Dropped rather than slowed, like every other movement in this app. What is left is the
    /// instant pin the transcript has always had, which is a whole answer rather than a degraded
    /// one, so this is a Bool and not an absent settle the way `TranscriptMotion.arrival` is.
    @Test("Reduce Motion is owed no travel")
    func reduceMotion() {
        #expect(TranscriptFollow.travels(reduceMotion: false))
        #expect(!TranscriptFollow.travels(reduceMotion: true))
    }

    // MARK: - Where the travel starts

    @Test("a row landing under a reader at the end is put back by its own height")
    func takesBackTheRow() {
        #expect(TranscriptFollow.start(offset: 10_000, end: 10_000, grew: 22, ownsGap: false) == 9_978)
    }

    /// A tool result unfolding, or a long answer landing whole. Travelling all of that would be a
    /// tour of what just arrived rather than a settle onto it.
    @Test("a tall arrival is capped rather than travelled in full")
    func capsTheTakeBack() {
        let offset = TranscriptFollow.start(offset: 10_000, end: 10_000, grew: 4_000, ownsGap: false)
        #expect(offset == 10_000 - TranscriptFollow.takeBack)
    }

    /// The pill is drawn from a measurement that can be a frame stale, so a full take-back has to
    /// still read as being at the end by the same rule the pill uses.
    @Test("a full take-back still counts as being at the end")
    func takeBackStaysBelowTheThreshold() {
        let end = 10_000.0
        let offset = TranscriptFollow.start(offset: end, end: end, grew: 5_000, ownsGap: false)
        #expect(
            ScrollEnd.isAtEnd(contentHeight: end + 700, viewportHeight: 700, offset: offset)
        )
    }

    @Test("nothing arriving is nothing to take back")
    func noGrowthNoTakeBack() {
        #expect(TranscriptFollow.start(offset: 10_000, end: 10_000, grew: 0, ownsGap: false) == 10_000)
    }

    /// The coalescing rule, and the reason this is an approach rather than an animation with a
    /// length: a second arrival mid travel moves the target and leaves the travel alone.
    @Test("an arrival mid travel does not start the travel again")
    func doesNotRestartMidTravel() {
        let end = 10_000.0
        let midTravel = end - 40
        #expect(TranscriptFollow.start(offset: midTravel, end: end, grew: 22, ownsGap: false) == midTravel)
    }

    // MARK: - The travel itself

    @Test("the gap closes, monotonically, and arrives")
    func closesTheGap() {
        var offset = 10_000 - TranscriptFollow.takeBack
        let end = 10_000.0
        var frames = 0
        var last = offset

        while frames < 240 {
            guard case .settle(let next) = TranscriptFollow.step(
                offset: offset, end: end, frame: 1 / 120, ownsGap: false
            ) else { break }
            #expect(next > last || next == end)
            last = next
            offset = next
            frames += 1
            if offset == end { break }
        }

        #expect(offset == end)
        // A quarter of a second at 120Hz is thirty frames, and this is the same quarter of a
        // second the jump pill's travel takes. Generous on both sides: what is being held down is
        // that it is neither instant nor an effect.
        #expect(frames > 4)
        #expect(frames < 60)
    }

    /// Most of the movement early and the rest of it arriving, which is what makes a short travel
    /// read as a settle rather than as a slide.
    @Test("most of the distance goes in the first third")
    func frontLoaded() {
        let end = 10_000.0
        var offset = end - TranscriptFollow.takeBack
        // A twelfth of a second, which is a third of the quarter second the whole travel takes.
        for _ in 0..<10 {
            guard case .settle(let next) = TranscriptFollow.step(
                offset: offset, end: end, frame: 1 / 120, ownsGap: false
            ) else { break }
            offset = next
        }
        let covered = (offset - (end - TranscriptFollow.takeBack)) / TranscriptFollow.takeBack
        #expect(covered > 0.5)
    }

    /// A display link starved by a layout pass over a long transcript hands back the whole gap
    /// since the last frame. Integrating that literally is the teleport this exists to replace.
    @Test("a late frame is not a licence to teleport")
    func clampsALateFrame() {
        let end = 10_000.0
        let offset = end - TranscriptFollow.takeBack
        guard case .settle(let next) = TranscriptFollow.step(
            offset: offset, end: end, frame: 4, ownsGap: false
        ) else {
            Issue.record("a late frame should still move the view")
            return
        }
        let sameAsAnOrdinaryLongFrame = TranscriptFollow.step(
            offset: offset, end: end, frame: TranscriptFollow.longestFrame, ownsGap: false
        )
        #expect(sameAsAnOrdinaryLongFrame == .settle(next))
        #expect(next < end)
    }

    /// The offset goes to a clip view whose origin is snapped to the backing store, so a step
    /// under a pixel is read back as no step at all and the same step is computed again for ever.
    /// Filmed against a real scroll view: the travel sat a point and a half short and stayed
    /// there. Every step from here to the end has to be worth at least a pixel.
    @Test("the last point closes rather than halving forever")
    func closesTheLastPoint() {
        let end = 10_000.0
        var offset = end - 1.5
        var steps = 0

        while steps < 10 {
            guard case .settle(let next) = TranscriptFollow.step(
                offset: offset, end: end, frame: 1 / 120, ownsGap: false
            ) else { break }
            #expect(next - offset >= min(end - offset, TranscriptFollow.smallestStep) - 0.000_1)
            offset = next
            steps += 1
            if offset == end { break }
        }

        #expect(offset == end)
        #expect(steps <= 2)
    }

    @Test("a step never carries the view past the end")
    func neverOvershoots() {
        let end = 10_000.0
        for gap in stride(from: 0.6, through: TranscriptFollow.takeBack, by: 0.3) {
            guard case .settle(let next) = TranscriptFollow.step(
                offset: end - gap, end: end, frame: 1 / 120, ownsGap: false
            ) else { continue }
            #expect(next <= end)
        }
    }

    @Test("a frame of no time at all moves nothing")
    func zeroFrame() {
        let end = 10_000.0
        #expect(TranscriptFollow.step(offset: end - 40, end: end, frame: 0, ownsGap: false) == .rest)
        #expect(TranscriptFollow.step(offset: end - 40, end: end, frame: -1, ownsGap: false) == .rest)
    }

    /// The lag a steadily growing tail settles at is `rate * timeConstant`, and it has to stay
    /// under the threshold that puts the jump pill up, or following a turn would offer to take
    /// the reader to where they already are.
    @Test("a streaming tail is followed without ever looking scrolled away")
    func steadyGrowthStaysAtTheEnd() {
        var end = 10_000.0
        var offset = end
        let frame = 1.0 / 120
        // Six hundred points a second is faster than any agent prints: about a line of prose
        // every thirty milliseconds.
        let rate = 600.0

        for _ in 0..<600 {
            let grew = rate * frame
            end += grew
            offset = TranscriptFollow.start(offset: offset, end: end, grew: grew, ownsGap: true)
            if case .settle(let next) = TranscriptFollow.step(offset: offset, end: end, frame: frame, ownsGap: true) {
                offset = next
            }
            #expect(
                ScrollEnd.isAtEnd(contentHeight: end + 700, viewportHeight: 700, offset: offset)
            )
        }

        // And it is genuinely following rather than sitting still: the lag settles at about
        // `rate * timeConstant` and never runs away.
        #expect(end - offset < TranscriptFollow.takeBack)
    }

    // MARK: - Whose gap it is

    /// **The stranding, which is the "it stops following half way through a turn" report.** A
    /// stored row replacing the tail with a taller block, or one starved display link frame, opens
    /// more than the pill's threshold in a single step while the view is mid travel. The distance
    /// alone said "somebody is reading up there" and the following gave up for the rest of the
    /// turn.
    @Test("a gap this object opened itself is caught up rather than given up")
    func recoversItsOwnGap() {
        let end = 10_000.0
        let stranded = end - 300
        #expect(
            TranscriptFollow.step(offset: stranded, end: end, frame: 1 / 120, ownsGap: false)
                == .rest
        )
        #expect(
            TranscriptFollow.step(offset: stranded, end: end, frame: 1 / 120, ownsGap: true)
                == .settle(end - TranscriptFollow.takeBack)
        )
    }

    /// And what is left after the jump is a travel rather than an arrival, so the catching up is
    /// still something the eye can follow.
    @Test("catching up lands a take-back short, and travels the rest")
    func catchingUpLeavesATravel() {
        let end = 10_000.0
        guard case .settle(let jumped) = TranscriptFollow.step(
            offset: end - 4_000, end: end, frame: 1 / 120, ownsGap: true
        ) else {
            Issue.record("a gap of its own should be caught up")
            return
        }
        #expect(jumped < end)
        #expect(end - jumped == TranscriptFollow.takeBack)
        guard case .settle(let next) = TranscriptFollow.step(
            offset: jumped, end: end, frame: 1 / 120, ownsGap: true
        ) else {
            Issue.record("and then travelled")
            return
        }
        #expect(next > jumped)
        #expect(next < end)
    }

    /// The other half of the fix, and the one that stops the gap opening in the first place: an
    /// arrival mid travel adds its own height to a gap that is already open, and enough of them in
    /// a row put the view further from the end than the travel was ever willing to go.
    @Test("arrivals mid travel cannot open the gap past the take-back")
    func ownedGrowthIsCapped() {
        var end = 10_000.0
        var offset = end - 40
        for _ in 0..<20 {
            let grew = 400.0
            end += grew
            offset = TranscriptFollow.start(offset: offset, end: end, grew: grew, ownsGap: true)
            #expect(end - offset <= TranscriptFollow.takeBack)
        }
    }

    /// Below the cap the arithmetic hands back the offset it was given, which is the coalescing
    /// rule unchanged: a second arrival mid travel moves the target and leaves the travel alone.
    @Test("an owned arrival under the cap moves nothing")
    func ownedGrowthUnderTheCapIsANoOp() {
        let grew = 22.0
        let offset = 9_960.0
        // The end is read after the growth, which is what the display link does: the document is
        // measured, and what it grew by is the difference from the last frame.
        let end = 10_000.0 + grew
        #expect(TranscriptFollow.start(offset: offset, end: end, grew: grew, ownsGap: true) == offset)
    }

    /// A reader who has scrolled up is still nobody's business, and owning the last gap is not a
    /// licence: the caller stops owning it the moment anything else moves the view.
    @Test("a reader who has scrolled up is left alone whatever arrives")
    func aReaderIsStillLeftAlone() {
        #expect(TranscriptFollow.start(offset: 5_000, end: 10_000, grew: 400, ownsGap: false) == 5_000)
        #expect(
            TranscriptFollow.step(offset: 5_000, end: 10_000, frame: 1 / 120, ownsGap: false)
                == .rest
        )
    }
}
