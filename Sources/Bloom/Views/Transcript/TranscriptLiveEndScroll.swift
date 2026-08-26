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
/// The travel is not `NSAnimationContext` either, and that is worth a paragraph because it was the
/// obvious answer and it was tried. `clip.animator().setBoundsOrigin` reads and measures exactly
/// as well as what is here, and it cannot be stopped: `animator()` writes the model value straight
/// away and animates the layer towards it, so `bounds.origin` reports the end of the document
/// from the first frame, the clip view has no presentation layer of its own to ask instead, and a
/// hand on the wheel therefore froze the view at the bottom rather than where the travel had got
/// to. That is the teleport this whole branch replaced, performed at the exact moment the reader
/// grabbed the view. Stepping the origin by hand means the current position is simply known.
///
/// What is given up is that SwiftUI's own `ScrollPosition` does not know where the view ended up,
/// which is why the caller settles it with an unanimated `scrollTo(edge: .bottom)` on arrival.
/// That call was already there for the streaming case. It is now what every completed travel ends
/// with, and a travel that was stopped does not reach it.
///
/// It fails safe. The scroll view is found through `enclosingScrollView` from a zero sized view
/// planted inside the content, and if SwiftUI ever stops backing its `ScrollView` with an
/// `NSScrollView` the answer is nil, `glide` returns false, and the caller jumps instead. A press
/// that arrives instantly is the behaviour this branch replaced and is not a failure.
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
        // The clip view's own height, not the scroll view's frame: an inset or a ruler makes those
        // different, and the one that decides how far the document can go is the area showing it.
        let reach = document.bounds.height - clip.bounds.height
        guard reach > 0 else { return false }

        // Flipped is what every scroll view in this app is, SwiftUI's included, but it is asked
        // rather than assumed: unflipped, the end of the document is at the origin, and travelling
        // to `reach` would go the wrong way.
        let end = document.isFlipped ? reach : 0
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

/// Plants a zero sized view inside the transcript's scroll content so the scroll view behind it
/// can be reached. Inside the content on purpose: `enclosingScrollView` walks up from the view it
/// is asked of, and a background on the `ScrollView` itself is a sibling of the scroll view rather
/// than a descendant of it, so it would answer nil, or find the composer's.
struct TranscriptScrollBridge: NSViewRepresentable {
    let scroller: TranscriptLiveEndScroller
    /// The other thing that moves this scroll view: what keeps up with a running turn. Fed from
    /// here rather than from a bridge of its own, so there is one view planted in the content and
    /// one answer about which scroll view the transcript is in.
    let follower: TranscriptLiveEndFollower

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Every layout pass rather than once on attach. The pane is reused for every workspace the
        // window visits and SwiftUI is free to rebuild the hosting scroll view underneath it, so a
        // reference taken once goes stale in exactly the case that matters.
        //
        // It is also the only chance either of these gets. Measured against a bare hosted
        // `ScrollView`, `enclosingScrollView` is nil on the first update, because the
        // representable's view is created before it is put in the hierarchy: the scroll view is
        // there from the second update on. Anything that took the reference once, on attach, would
        // hold nil for ever and every travel below would silently fall back to a jump.
        //
        // **SPIKE: downward first, upward second.** With a `List` there is nowhere inside the
        // content to plant this: a row is recycled the moment it leaves the viewport, so anything
        // hung on a row is destroyed as soon as a long session is scrolled. So the transcript
        // hangs it on the list's background instead, where `enclosingScrollView` answers nil or,
        // worse, finds whatever scroll view the pane itself is inside. The table's own scroll view
        // is a SIBLING of the background, so it is found by walking up a few levels and searching
        // down. The `ScrollView` variant is unaffected: this still walks up first for it, and the
        // downward search only runs when that answers nothing.
        let found = nsView.enclosingScrollView ?? Self.scrollView(near: nsView)
        if scroller.scrollView !== found { scroller.scrollView = found }
        if follower.scrollView !== found { follower.scrollView = found }
    }

    /// The scroll view a sibling of this view is the document of, if there is one.
    ///
    /// Bounded rather than unbounded, in both directions: a search that climbs to the window and
    /// walks the whole view tree would find the terminal's scroll view, or the inspector's, on a
    /// pane where the transcript's has not been built yet.
    private static func scrollView(near view: NSView) -> NSScrollView? {
        var node = view.superview
        var climbed = 0
        while let current = node, climbed < 6 {
            if let found = descendantScrollView(of: current, depth: 0) { return found }
            node = current.superview
            climbed += 1
        }
        return nil
    }

    private static func descendantScrollView(of view: NSView, depth: Int) -> NSScrollView? {
        guard depth < 8 else { return nil }
        for sub in view.subviews {
            if let scroll = sub as? NSScrollView, scroll.documentView != nil { return scroll }
            if let found = descendantScrollView(of: sub, depth: depth + 1) { return found }
        }
        return nil
    }
}
