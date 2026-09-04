import AppKit
import BloomCore
import QuartzCore
import SwiftUI

/// Keeps the transcript with the newest row while a turn runs, and makes the last of that travel
/// something the eye can follow instead of a jolt.
///
/// **The rules are `TranscriptFollow`'s and the frames are here.** What this file owns is when the
/// following is on at all.
///
/// ## Why this is not a `withAnimation` on the scroll position
///
/// For the reason `TranscriptLiveEndScroller`'s header measures, and a second one on top of it:
/// this runs while a turn streams, so a state write per frame would re-run the list's body and
/// rebuild every realised row with it. Nothing here writes any SwiftUI state. It reads two heights
/// off AppKit and sets an origin, and the transcript's geometry callback picks the result up as if
/// the reader had scrolled there themselves.
///
/// ## The take-back, and why it is the shape of the thing
///
/// Something else pins the view to the end in the same pass that grows the content
/// (`TranscriptTableController.goToEnd`), so by the time any frame is drawn there is nothing left
/// to animate. The travel has to be made rather than intercepted, which is what
/// `TranscriptFollow.start` is: the view is put back by what arrived, capped, and travels forward
/// again. One frame of the pinned position may be shown first, which at 120Hz has no visible
/// width. With nothing pinning, the view is simply behind by what arrived and the same approach
/// carries it forward.
///
/// ## What turns it off
///
/// Reduce Motion, through `TranscriptFollow.travels`. A window that is not in front, because a
/// display link in a backgrounded app is the battery bug `ActivityDot` measured. A hand on the
/// wheel. And a quiet transcript: the link is up only while a turn streams or for a moment after
/// a row lands.
@MainActor
final class TranscriptLiveEndFollower {
    /// Weak, because the scroll view belongs to the view hierarchy and holding it here would keep
    /// a pane's worth of realised rows alive after the pane has gone. It is handed over by
    /// `TranscriptTable`, which owns it.
    weak var scrollView: NSScrollView? {
        didSet {
            guard scrollView !== oldValue else { return }
            lastHeight = 0
            forgetTheView()
            // And re-ask, like every other input below: the scroll view arrives after the first
            // pass, so a turn that started streaming before it landed set `isStreaming` while
            // `wants` was still false for want of a view, and nothing asked again.
            refresh()
        }
    }

    /// Whether a turn is streaming into this transcript. The tail grows without any row landing,
    /// so this is what keeps the link up between rows.
    var isStreaming = false { didSet { refresh() } }

    /// Whether this window is the one in front. See the header.
    var isFrontmost = true { didSet { refresh() } }

    /// Whether the reader has hold of the view. Anything that is not an idle scroll phase.
    var isPaused = false { didSet { refresh() } }

    /// Whether there is a travel to make at all, which is `TranscriptFollow.travels` and is about
    /// Reduce Motion. False leaves the transcript with the instant pin it has always had.
    var travels = true { didSet { refresh() } }

    /// Called when the following stops with the view at the end, so the caller can take its
    /// standing instruction back.
    ///
    /// **This is what stops the transcript falling behind when the following is off.** While this
    /// object is driving, nothing else may put the view at the end, so this is the moment that
    /// instruction goes back. See `TranscriptTableController.goToEnd`.
    ///
    /// Only at the end, and never mid travel: naming the edge from anywhere else is a jump, and
    /// the reader who has just taken hold of the view is precisely who must not be given one.
    var onRest: (@MainActor () -> Void)?

    /// Called when the following starts, so whoever owns the scroll position can stop naming an
    /// edge and say whether that edge belonged to the follower.
    ///
    /// **Without this the follower cannot win an argument it is having every frame.** Whatever
    /// pins the view to the end does so on the layout pass that grew the content, so the take-back
    /// landed and was overwritten before a frame was drawn and what reached the screen was the
    /// instant pin with the travel invisible underneath it.
    ///
    /// The answer is ownership rather than a distance. A row can land before the display link's
    /// first frame and open a gap wider than any threshold, but if the table was holding the end
    /// that gap still belongs to this follower. Without carrying that fact across the handoff, the
    /// follower mistakes an arriving response for a reader who scrolled up and leaves it below the
    /// viewport.
    var onStart: (@MainActor () -> Bool)?

    /// Called whenever the link goes down, at the end or not.
    ///
    /// **`onRest` is not enough to hand the view back with.** It fires only when the travel
    /// finished AT the end. A reader who scrolled away mid travel, a window going behind another
    /// app or a session being left all leave the view in the middle, and whoever suppressed their
    /// own scrolling for the duration would suppress it for ever. See
    /// `TranscriptTableController.followerTookOver`.
    ///
    /// Said before `onRest`, so a caller that reacts to both gets "I have stopped" and then "and
    /// you are at the end" in that order.
    var onStop: (@MainActor () -> Void)?

    /// How long a row landing keeps the link up on its own.
    ///
    /// Long enough for the travel it started to finish, which `TranscriptFollow` settles in about
    /// a quarter of a second, plus room for the next row of the same turn to land into the same
    /// link rather than starting another. The cost of being generous is a few frames of reading
    /// two numbers.
    private static let grace: Double = 0.5

    private var link: CADisplayLink?
    private var deadline: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    /// The document height the last frame saw, which is how growth is noticed without anything
    /// having to report it. Nought means "not measured yet", so the first frame after attaching
    /// to a scroll view never reads a pane's worth of content as an arrival.
    private var lastHeight: CGFloat = 0

    /// Where this object last left the clip view, and whether the view is still there.
    ///
    /// **This is the flag that used to be a distance.** `TranscriptFollow` gave up on a gap wider
    /// than `ScrollEnd.threshold`, which was the only thing keeping a reader who had scrolled up
    /// safe, and it also abandoned a travel of this object's own that had fallen behind. Two
    /// questions, one number. Content growing does not move the offset and a reader does, so the
    /// two are told apart by reading the clip view back: a view that has gone UP since the last
    /// frame was taken by somebody else, and a reader on a mouse that posts no live scroll phases
    /// is exactly who that is (see `TranscriptTable.Coordinator.clipMoved`, which makes the same
    /// deduction for the same reason). Down is either us or something pinning the end, and neither
    /// is a reader leaving.
    private var lastPut: CGFloat?
    private var ownsGap = false

    /// Whether this object is holding the view at the live end: the link is up and the view is
    /// still where it put it.
    ///
    /// Read by the pane when it writes down where the reader was. Mid travel the view is up to
    /// `TranscriptFollow.takeBack` behind the end on purpose, and a pane that wrote that down
    /// exactly would remember somebody who was watching a turn arrive as somebody who had
    /// scrolled up, and bring them back anchored to a row while the agent went on writing.
    var isFollowing: Bool { link != nil && ownsGap }

    /// A row has landed. Keeps the following up for a moment even if nothing is streaming.
    func nudge() {
        deadline = CACurrentMediaTime() + Self.grace
        refresh()
    }

    /// Ends the following and forgets what it had measured. What a session change calls: the next
    /// transcript's first frame must not read the difference between two conversations as content
    /// arriving.
    func stop() {
        deadline = 0
        forget()
        forgetTheView()
        // Without the handback: a conversation the pane has left is owed nothing, and naming an
        // edge on the way out would land on whichever session arrives next.
        dropLink()
    }

    /// Forgets the height it had measured, without ending anything.
    ///
    /// What the history reveal calls. Putting a session's whole history back behind its tail grows
    /// the document by everything above the viewport in one pass, and that is the pane being
    /// filled in rather than a line arriving in front of the reader. Re-baselining on the next
    /// frame is the difference between that landing silently, which is the intention, and the
    /// arrival of a workspace ending on a settle nobody asked for.
    func forget() {
        lastHeight = 0
    }

    /// Forgets that the view is ours, so the next frame reads the gap as somebody else's until
    /// this object has placed the view itself.
    private func forgetTheView() {
        lastPut = nil
        ownsGap = false
    }

    // MARK: - The link

    private var wants: Bool {
        guard travels, isFrontmost, !isPaused, scrollView != nil else { return false }
        return isStreaming || CACurrentMediaTime() < deadline
    }

    private func refresh() {
        if wants { startLink() } else { endLink() }
    }

    private func startLink() {
        guard link == nil, let scrollView else { return }
        lastFrame = 0
        forgetTheView()
        // Before the first frame runs, so the very first take-back is not overwritten by the pin
        // it is trying to take back from. See `onStart`.
        ownsGap = onStart?() ?? false
        if ownsGap { lastPut = scrollView.contentView.bounds.origin.y }
        let created = scrollView.contentView.displayLink(target: self, selector: #selector(step))
        created.add(to: .main, forMode: .common)
        link = created
    }

    /// Ends the link and hands the standing bottom edge back to whoever gave it up. See `onRest`.
    private func endLink() {
        guard dropLink() else { return }
        // The ordinary handback: the travel finished at the end.
        if isAtEnd {
            onRest?()
            return
        }
        // **And the belt, which is the other half of "it stops following and never starts again".**
        // A link coming down short of the end used to say nothing at all, so the instruction never
        // went back and the transcript sat where the last frame left it for the rest of the
        // session. It is safe exactly when nothing else has taken the view: a hand on the wheel is
        // `isPaused`, and anything that moved the view itself has already cleared `ownsGap`. The
        // caller guards again on its own account, because a reader mid gesture must not be given
        // an edge whatever this thinks: see `TranscriptTableController.goToEnd`.
        guard !isPaused, ownsGap else { return }
        onRest?()
    }

    /// Takes the link down, and says whether there was one. Nothing else.
    @discardableResult
    private func dropLink() -> Bool {
        guard link != nil else { return false }
        link?.invalidate()
        link = nil
        onStop?()
        return true
    }

    private var isAtEnd: Bool {
        guard let scrollView else { return false }
        // `TranscriptFollow.arrived`, which is about a travel being spent rather than watched, and
        // deliberately not `NSScrollView.isAtEnd`'s exact point.
        return scrollView.distanceFromEnd <= TranscriptFollow.arrived
    }

    @objc private func step(_ sender: CADisplayLink) {
        MainActor.assumeIsolated {
            guard wants, let scrollView, let document = scrollView.documentView else { return endLink() }
            // Flipped is what every scroll view in this app is, SwiftUI's included, but it is
            // asked rather than assumed: unflipped, the end of the document is at the origin and
            // everything below would be aimed the wrong way. See `TranscriptLiveEndScroller`.
            guard document.isFlipped else { return endLink() }

            let clip = scrollView.contentView
            // The same refusal `TranscriptTable.Coordinator.put` makes, because this is the other
            // thing that writes the clip view and it runs at display rate for the whole of a turn,
            // which is when a divider is most likely to be under a hand. See
            // `TranscriptAnchor.canPlace`: `endOffset` against a pane of no height is the point
            // below the last row.
            guard TranscriptAnchor.canPlace(viewportHeight: Double(clip.bounds.height)) else {
                return
            }
            let now = CACurrentMediaTime()
            let frame = lastFrame > 0 ? now - lastFrame : 0
            lastFrame = now

            let height = document.frame.height
            let end = scrollView.endOffset
            var offset = clip.bounds.origin.y

            // Whose gap this is, decided before anything is done with it. Upwards only: see
            // `lastPut`.
            if let lastPut, offset < lastPut - CGFloat(TranscriptFollow.arrived) { ownsGap = false }

            if lastHeight > 0, height > lastHeight {
                offset = TranscriptFollow.start(
                    offset: offset, end: end, grew: height - lastHeight, ownsGap: ownsGap
                )
            }
            lastHeight = height

            switch TranscriptFollow.step(offset: offset, end: end, frame: frame, ownsGap: ownsGap) {
            case .rest:
                // The take-back still has to land even on a frame with no travel left in it,
                // which is the frame a row lands on when the display link is running late.
                if offset != clip.bounds.origin.y { put(offset, in: clip, of: scrollView) }
            case .settle(let next):
                put(next, in: clip, of: scrollView)
            }

            if !isStreaming, now >= deadline { endLink() }
        }
    }

    private func put(_ y: CGFloat, in clip: NSClipView, of scrollView: NSScrollView) {
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        // Read back rather than remembered, because a clip view snaps its origin to the backing
        // store and clamps it to the document: what the next frame compares against has to be
        // where the view actually is, or every frame would read its own rounding as a reader.
        lastPut = clip.bounds.origin.y
        ownsGap = true
    }
}
