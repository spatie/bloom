import AppKit
import BloomCore
import QuartzCore
import SwiftUI

/// Keeps the transcript with the newest row while a turn runs, and makes the last of that travel
/// something the eye can follow instead of a jolt.
///
/// **The rules are `TranscriptFollow`'s and the frames are here.** What this file owns is when the
/// following is on at all, and one measurement about SwiftUI that the shape of it depends on.
///
/// ## Why this is not a `withAnimation` on the scroll position
///
/// For the same reason `TranscriptLiveEndScroller` is not, and that file carries the frame timings
/// that settled it: on a long transcript SwiftUI's own animated scroll delivered a fifth of the
/// frames the display wanted at six times the main-thread cost of stepping the clip view by hand.
/// This one has a second reason on top of that. It runs while a turn streams, which is many
/// content changes a second, and a state write per frame would re-run the list's body and rebuild
/// every realised row with it. Nothing here writes any SwiftUI state at all: it reads two heights
/// off AppKit and sets an origin, and `onScrollGeometryChange` picks the result up as if the
/// reader had scrolled there themselves, so the jump pill and the size-change anchor keep working
/// off exactly the numbers they already did.
///
/// ## The take-back, and why it is the shape of the thing
///
/// A `ScrollPosition` standing at `.bottom` keeps the view pinned to the end as the content grows,
/// in the same layout pass that grows it. There is nothing to animate after that: by the time any
/// frame is drawn the view is already at the end. So the travel has to be made rather than
/// intercepted, and that is what `TranscriptFollow.start` is: on the frame that sees the content
/// grow, the view is put back by what arrived, capped, and then travels forward to the end again.
/// One frame of the pinned position may be shown before the take-back lands, which at 120Hz is
/// eight milliseconds and has no visible width.
///
/// It costs nothing when SwiftUI does not pin. Then the view is simply behind the end by what
/// arrived, `start` leaves it there, and the same approach carries it forward. Both worlds end up
/// travelling the same distance at the same rate.
///
/// ## What turns it off
///
/// Reduce Motion, which drops the travel rather than slowing it, the way every other movement in
/// this app does, and which is `TranscriptFollow.travels` rather than a reading of the setting
/// taken here. A window that is not in front, because a display link in a backgrounded app is
/// the battery bug `ActivityDot` carries the measurement for and there is nobody watching the
/// travel anyway. A hand on the wheel, because a view that goes on dragging somebody somewhere
/// after they have taken hold of it is the worst thing this file could do. And a quiet transcript:
/// the link is only up while a turn is streaming or for a moment after a row lands, so a session
/// nobody is running costs nothing at all.
@MainActor
final class TranscriptLiveEndFollower {
    /// Weak, because the scroll view belongs to the view hierarchy and holding it here would keep
    /// a pane's worth of realised rows alive after the pane has gone. See `TranscriptScrollBridge`.
    weak var scrollView: NSScrollView? {
        didSet {
            guard scrollView !== oldValue else { return }
            lastHeight = 0
            // And re-ask, like every other input below. `wants` reads this property, and
            // `TranscriptScrollBridge` measured that `enclosingScrollView` is nil on the first
            // update: a turn that starts streaming before the second layout pass therefore set
            // `isStreaming` while `wants` was still false for want of a view, and nothing asked
            // again. The following stayed off until the next `nudge()` or state change.
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

    /// Called when the following stops with the view at the end, so the caller can hand SwiftUI
    /// its standing instruction back.
    ///
    /// **This is not tidiness, it is what stops the transcript falling behind when the following
    /// is off.** Measured against a hosted `ScrollView` whose `ScrollPosition` was standing at
    /// `.bottom`: content growing kept the view at the end, to the point, until the clip view was
    /// moved by hand, and from that moment on it never kept it again. SwiftUI takes a position it
    /// did not make as the reader having scrolled, which is exactly right and is why the pill
    /// works, but it means the first frame this follower steps also puts SwiftUI's own following
    /// down. So when the travel is over, whoever owns the scroll position says the edge again, and
    /// the instant pin is back for the window that is behind another app, the reader who has asked
    /// for less movement, and the quiet transcript nobody is running.
    ///
    /// Only at the end, and never mid travel: naming the edge from anywhere else is a jump, and
    /// the reader who has just taken hold of the view is precisely who must not be given one.
    var onRest: (@MainActor () -> Void)?

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
        return true
    }

    private var isAtEnd: Bool {
        guard let scrollView, let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        return document.bounds.height - clip.bounds.height - clip.bounds.origin.y
            <= TranscriptFollow.arrived
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

            // The clip view's own height, not the scroll view's frame: an inset or a ruler makes
            // those different, and the one that decides how far the document can go is the area
            // showing it.
            let height = document.bounds.height
            let end = height - clip.bounds.height
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
