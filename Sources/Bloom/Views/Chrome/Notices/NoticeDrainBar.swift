import SwiftUI
import AppKit

/// The line along the bottom of `NoticeBanner` that says how long is left.
///
/// It drains rather than fills. A bar that fills is a job being done and asks to be waited for; a
/// bar that empties is time being spent, which is what this actually is, and it needs no label to
/// say so. Left anchored, so what is left of it stays where the sentence starts.
///
/// **A layer rather than SwiftUI.** The whole travel is one `transform.scale.x` on one layer, which
/// the render server owns: nothing is re-laid out, nothing is re-pathed, and SwiftUI is not woken
/// once between the start and the end. That is also the only way to ask for a frame rate, which is
/// the point below.
struct NoticeDrainBar: NSViewRepresentable {
    /// How much of the bar is left, from one down to nothing, at the instant this update happens.
    var fraction: Double
    /// How long the rest of the drain has to take, or nothing while the pointer is holding it.
    var remaining: Duration?
    /// Bumped by the banner every time the drain has to be restated: a new notice, a pause, a
    /// resume. The view redraws for other reasons too, and re-adding the animation on any of those
    /// would put the bar back to `fraction` and run it again from there.
    var generation: Int
    /// What the bar is painted in. The accent for a notice, which is what this was written for;
    /// `RetryRowView` hands it the warning tint so the bar under a turn that has been retrying for
    /// two minutes belongs to the plate it sits on rather than to the app's own accent.
    var tint: Color = Palette.accent

    func makeNSView(context: Context) -> NoticeDrainBarView { NoticeDrainBarView() }

    func updateNSView(_ view: NoticeDrainBarView, context: Context) {
        view.tint = NSColor(tint)
        view.apply(fraction: fraction, remaining: remaining, generation: generation)
    }
}

final class NoticeDrainBarView: NSView {
    private let track = CALayer()
    private let bar = CALayer()
    private var generation = -1
    private var fraction: Double = 1
    private var remaining: Duration?
    /// Set by the representable before every `apply`. It is resolved to a `CGColor` inside
    /// `applyColours`, which is the one place that may do so: see the note there.
    var tint: NSColor = Palette.accentNSColor {
        didSet { if tint != oldValue { applyColours() } }
    }

    /// Faster than the twelve frames a second `BrandWater` and `BrandBranching` are capped at, and
    /// for a reason those two do not have: they move soft fields whose brightest pixel changes by
    /// about two levels a second, where this moves a hard edge across four hundred points in nine.
    /// At twelve frames that edge steps four points at a time and reads as a ratchet.
    ///
    /// Twenty is where the step comes down to about two and a half points, which at this contrast
    /// is under what the eye picks out of something nobody is tracking. It is still a sixth of what
    /// this display would otherwise give it. That matters here for the same measured reason it
    /// mattered there: uncapped, an animation in this window had WindowServer spending forty to
    /// fifty percent of one core recompositing pictures indistinguishable from each other.
    private static let frameRate = CAFrameRateRange(minimum: 10, maximum: 24, preferred: 20)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(bar)
        // Anchored at the leading edge, so scaling the layer shortens it from the trailing end and
        // the remaining time stays under the start of the sentence.
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.anchorPoint = CGPoint(x: 0, y: 0.5)
        applyColours()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        // Bounds and position rather than `frame`, because the bar carries a scale transform and
        // what `frame` means on a transformed layer is not defined. No implicit animation either:
        // the window can be dragged wider mid drain, and the drain itself is the transform, which
        // a change of bounds leaves running and correct.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [track, bar] {
            layer.bounds = CGRect(origin: .zero, size: bounds.size)
            layer.position = CGPoint(x: 0, y: bounds.midY)
        }
        CATransaction.commit()
        // Only when there is nothing to keep. The first layout is where the bar finally has a
        // width, and `apply` before that could not start anything; every later one must not put a
        // drain half spent back to the top.
        if bar.animation(forKey: "drain") == nil { restate() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    func apply(fraction: Double, remaining: Duration?, generation: Int) {
        guard generation != self.generation else { return }
        self.generation = generation
        self.fraction = min(max(fraction, 0), 1)
        self.remaining = remaining
        restate()
    }

    private func restate() {
        bar.removeAnimation(forKey: "drain")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.transform = CATransform3DMakeScale(fraction, 1, 1)
        CATransaction.commit()

        guard let remaining, remaining > .zero, bounds.width > 0 else { return }
        let drain = CABasicAnimation(keyPath: "transform.scale.x")
        drain.fromValue = fraction
        drain.toValue = 0
        drain.duration = remaining.seconds
        // Linear, because the bar is a clock. Any easing would have it claim that time passes
        // faster at one end of the wait than the other.
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        drain.fillMode = .forwards
        drain.isRemovedOnCompletion = false
        drain.preferredFrameRateRange = Self.frameRate
        bar.add(drain, forKey: "drain")
    }

    /// Resolved against this view's appearance, which is the only place a `CGColor` may be taken
    /// from an `NSColor` that answers per appearance: a `CGColor` has no appearance to track, so
    /// one taken outside this block stays whatever the window happened to be when the banner opened.
    private func applyColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = tint
            // Quiet on purpose. The bar sits under a sentence and must not be the thing that is
            // read first: a tenth of the accent for the ground it runs on, and a little under two
            // thirds for the bar itself, which lands a step below the icon above it in both
            // appearances.
            track.backgroundColor = accent.withAlphaComponent(0.10).cgColor
            bar.backgroundColor = accent.withAlphaComponent(0.6).cgColor
        }
    }

    /// Not a hit target. The banner's own hover is what pauses the drain, and a subview that
    /// answered a hit test would put a hole in the middle of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension Duration {
    /// Seconds as a `CFTimeInterval`, for the handful of places that hand a `Duration` to Core
    /// Animation. Whole seconds plus the attoseconds, which is the only lossless way out of the
    /// pair and the reason this is not `Double(components.seconds)`.
    var seconds: CFTimeInterval {
        CFTimeInterval(components.seconds) + CFTimeInterval(components.attoseconds) / 1e18
    }
}
