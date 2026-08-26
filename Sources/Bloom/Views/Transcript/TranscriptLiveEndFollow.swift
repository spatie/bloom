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

    /// Called with the current offset when the following starts, so whoever owns the scroll
    /// position can stop naming an edge.
    ///
    /// **Without this the follower cannot win an argument it is having every frame.** Whatever
    /// pins the view to the end does so on the layout pass that grew the content, so the take-back
    /// landed and was overwritten before a frame was drawn and what reached the screen was the
    /// instant pin with the travel invisible underneath it.
    ///
    /// The offset it hands over is the one the view is already at, so naming it moves nothing. The
    /// table's caller ignores the number and simply lets go of its own instruction.
    var onStart: (@MainActor (CGFloat) -> Void)?

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
        // Before the first frame runs, so the very first take-back is not overwritten by the pin
        // it is trying to take back from. See `onStart`.
        onStart?(scrollView.contentView.bounds.origin.y)
        let created = scrollView.contentView.displayLink(target: self, selector: #selector(step))
        created.add(to: .main, forMode: .common)
        link = created
    }

    /// Ends the link and, if the view is sitting at the end, hands SwiftUI its standing bottom
    /// edge back. See `onRest`.
    private func endLink() {
        guard dropLink(), isAtEnd else { return }
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
            let now = CACurrentMediaTime()
            let frame = lastFrame > 0 ? now - lastFrame : 0
            lastFrame = now

            let height = document.frame.height
            let end = scrollView.endOffset
            var offset = clip.bounds.origin.y

            if lastHeight > 0, height > lastHeight {
                offset = TranscriptFollow.start(offset: offset, end: end, grew: height - lastHeight)
            }
            lastHeight = height

            switch TranscriptFollow.step(offset: offset, end: end, frame: frame) {
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
    }
}
