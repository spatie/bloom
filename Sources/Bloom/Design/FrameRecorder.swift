import AppKit
import QuartzCore

/// Records when the main thread was free, once per vsync.
///
/// Shared by every probe in the family rather than private to one, because "how long did a frame
/// take" is the same question whether the gesture is a divider drag, a tab switch or a scroll, and
/// a second copy of a display link is a second chance to get the run loop mode wrong.
///
/// `CADisplayLink` rather than a timer, because a timer fires in whatever mode it was scheduled
/// for and a divider drag runs in `NSEventTrackingRunLoopMode`. Added to the common modes for the
/// same reason.
@MainActor
final class FrameRecorder {
    private var link: CADisplayLink?
    private let view: NSView
    /// The width the probe is supposed to be moving. Sampled once a frame so a run that measured
    /// a perfectly idle window can be told apart from a run whose synthetic drag never landed.
    private let observe: () -> CGFloat
    private var last: CFTimeInterval = 0
    private(set) var intervals: [Double] = []
    private(set) var widths: [CGFloat] = []
    private var isRecording = false

    init(view: NSView, observe: @escaping () -> CGFloat) {
        self.view = view
        self.observe = observe
    }

    func start() {
        intervals.removeAll()
        widths.removeAll()
        last = 0
        isRecording = true
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        isRecording = false
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        guard isRecording else { return }
        let now = CACurrentMediaTime()
        widths.append(observe())
        defer { last = now }
        guard last != 0 else { return }
        intervals.append(now - last)
    }
}
