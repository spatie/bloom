import AppKit
import QuartzCore
import SwiftUI

/// Drives the jump pill's travel back to the live end at AppKit's level rather than SwiftUI's.
///
/// **This exists because the SwiftUI spelling of it was measured and does not hold.**
/// `withAnimation(.easeOut(duration: 0.26)) { scrollPosition.scrollTo(edge: .bottom) }` is one
/// line and reads better than everything below. On a three thousand row transcript two hundred
/// thousand points long, alternating the two mechanisms press by press inside one process so the
/// machine's load cannot be the difference, it delivers 57 of the 288 frames a 120Hz display
/// wanted across eight presses, a mean of 30ms between frames and a worst gap of 108ms, with the
/// main thread at 74 per cent of a core. Stepping the clip view instead delivers 222 of 288, a
/// mean of 8.6ms, one gap over 33ms in eight presses, at 13 per cent of a core, which is what the
/// same press with no animation on it costs. WindowServer is not involved either way, which is the
/// one thing the numbers rule out.
///
/// **The travel is not `NSAnimationContext` either**, which was the obvious answer and was tried.
/// `clip.animator().setBoundsOrigin` measures as well as this and cannot be stopped: `animator()`
/// writes the model value straight away, so `bounds.origin` reports the end of the document from
/// the first frame and a hand on the wheel froze the view at the bottom rather than where the
/// travel had got to. That is the teleport this replaced, performed at the moment the reader
/// grabbed the view. Stepping the origin by hand means the current position is simply known.
///
/// It fails safe: with no scroll view `glide` returns false and the caller jumps instead.
@MainActor
@Observable
final class TranscriptLiveEndScroller {
    /// Weak, because the scroll view belongs to the view hierarchy and holding it here would keep
    /// a pane's worth of realised rows alive after the pane has gone.
    @ObservationIgnored weak var scrollView: NSScrollView?

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var start: CFTimeInterval = 0
    @ObservationIgnored private var from: CGFloat = 0
    @ObservationIgnored private var to: CGFloat = 0
    @ObservationIgnored private var duration: Double = 0
    @ObservationIgnored private var arrival: (@MainActor () -> Void)?

    /// Travels to the end of the content over `seconds`, and says whether it could.
    ///
    /// `completion` runs on arrival and only on arrival. A travel cut short by `stop`, replaced by
    /// a second press, or left behind by the pane changing session never calls it, because every
    /// one of those is somebody saying they no longer want to be taken there.
    @discardableResult
    func glide(seconds: Double, completion: @escaping @MainActor () -> Void) -> Bool {
        guard let scrollView, let document = scrollView.documentView else { return false }

        let clip = scrollView.contentView
        let reach = scrollView.endOffset
        guard reach > 0 else { return false }

        // Flipped is what every scroll view in this app is, SwiftUI's included, but it is asked
        // rather than assumed: unflipped, the end of the document is at the origin, and travelling
        // to `reach` would go the wrong way.
        let end = document.isFlipped ? reach : 0
        // Half a point is under a pixel, so there is nothing to travel. Its own number rather than
        // `TranscriptFollow.arrived`: the two agree because both are the same claim about a pixel,
        // not because one owns the other.
        guard abs(clip.bounds.origin.y - end) > 0.5, seconds > 0 else { return false }

        stop()
        from = clip.bounds.origin.y
        to = end
        duration = seconds
        start = CACurrentMediaTime()
        arrival = completion

        let created = clip.displayLink(target: self, selector: #selector(step))
        created.add(to: .main, forMode: .common)
        link = created
        return true
    }

    /// Ends any travel in flight, leaving the view exactly where it had got to.
    ///
    /// A hand on the wheel has to win on the frame it arrives, and a view that goes on dragging
    /// somebody somewhere after they have taken hold of it is the worst thing this file could do.
    /// Nothing is animated to a stop and nothing is settled afterwards.
    func stop() {
        link?.invalidate()
        link = nil
        arrival = nil
    }

    @objc private func step(_ sender: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let scrollView else { return stop() }
            let clip = scrollView.contentView
            let elapsed = CACurrentMediaTime() - start
            let ratio = duration > 0 ? min(1, max(0, elapsed / duration)) : 1
            // The same ease out the SwiftUI spelling asked for: fast at the top of the movement,
            // settling at the bottom of it, so the travel reads as arriving rather than stopping.
            let eased = 1 - pow(1 - ratio, 3)
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: from + (to - from) * eased))
            scrollView.reflectScrolledClipView(clip)

            guard ratio >= 1 else { return }
            let landed = arrival
            stop()
            landed?()
        }
    }
}
