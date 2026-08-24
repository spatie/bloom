import SwiftUI
import AppKit
import QuartzCore
import BloomCore

/// A mark that breathes on the window's heartbeat: the retrying turn's glyph, and anything else
/// that has to say "still here" for minutes at a time.
///
/// # Why it is a layer and not a `keyframeAnimator`
///
/// The same argument `PulsingDot` carries, applied to the one repeating SwiftUI animation left in
/// the transcript. A `keyframeAnimator(repeating: true)` is not handed to the render server:
/// SwiftUI interpolates it on the main thread and re-renders the hosting view's display list every
/// frame, so the bill is set by the size of the window rather than by the size of the mark.
/// `BusyPulse`'s header carries the measurement, taken on this app: 320,971 view graph updates for
/// 12 body evaluations over 12.3 seconds, with `RootGeometry` and `LayoutChildGeometries`
/// recomputed 239.6 times a second. A retry runs for as long as somebody else's outage lasts, which
/// is minutes.
///
/// **It keeps moving when the window is behind another app, and that is deliberate.** `0142c5f`
/// removed every frontmost gate in Bloom: a mark that says "this is still going" is at its most
/// useful in a window somebody has put to one side, and a `CAAnimation` is interpolated in the
/// render server on the display's own clock, so parking it saves nothing. `Reduce Motion` is the
/// one thing that holds it still, and it is read by `BusyPulseDriver` in one place. See `BusyPulse`.
///
/// # Why it hosts the mark rather than drawing it
///
/// The figure stays a SwiftUI view and only the opacity moves to a layer. An AppKit redrawing of an
/// SF Symbol would have to match `TranscriptGlyph`'s point size, weight and scale by hand, and a
/// mark half a point out of the column it shares with every other row in the transcript is a worse
/// outcome than the animation it was trying to make cheaper. The hosting view is a subview rather
/// than the animated layer itself, so the animation lives on a layer SwiftUI does not own and
/// cannot reset from inside.
struct BreathingMark<Content: View>: View {
    /// False for a mark that is present but still: the snapshot run, and `Reduce Motion`.
    var isMoving = true

    @ViewBuilder var content: () -> Content

    private var pulse: BusyPulse { .shared }

    var body: some View {
        if isMoving && pulse.isTicking {
            BreathingMarkHost(epoch: pulse.epoch, content: content())
        } else {
            // Deliberately not the layer. Only the moving state has anything to gain from Core
            // Animation, and keeping the still one in SwiftUI is what lets `ImageRenderer`
            // photograph a mark that is not breathing: it cannot draw an `NSViewRepresentable` at
            // all, and paints one as a yellow placeholder. See `Snapshot`.
            content()
        }
    }
}

private struct BreathingMarkHost<Content: View>: NSViewRepresentable {
    /// The heartbeat's start, which is the only thing that decides where in its breath the mark is.
    /// See `BusyPulse.epoch`.
    var epoch: CFTimeInterval

    var content: Content

    func makeNSView(context: Context) -> BreathingMarkView<Content> {
        let view = BreathingMarkView(content: content)
        view.configure(epoch: epoch, content: content)
        return view
    }

    func updateNSView(_ view: BreathingMarkView<Content>, context: Context) {
        view.configure(epoch: epoch, content: content)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: BreathingMarkView<Content>, context: Context
    ) -> CGSize? {
        nsView.fittingSize
    }
}

/// The hosted mark, under a repeating fade.
final class BreathingMarkView<Content: View>: BusyPulseLayerView {
    private let hosting: NSHostingView<Content>
    private var epoch: CFTimeInterval = 0

    init(content: Content) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        // A glyph is drawn inside its own column and does not grow, but a mark that overflowed its
        // box would be flattened against the edge rather than clipped politely, and rasterising a
        // sixteen point box to find out is a cost nobody asked for.
        layer?.masksToBounds = false
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { hosting.intrinsicContentSize }

    /// Guarded, because `updateNSView` runs whenever the view around it is rebuilt, and a retry row
    /// is rebuilt on every announcement. Reinstalling an animation that is already correct would
    /// reset its phase, and the phase is what puts this mark on the window's one heartbeat.
    func configure(epoch: CFTimeInterval, content: Content) {
        hosting.rootView = content
        guard epoch != self.epoch else { return }
        self.epoch = epoch
        install()
    }

    private func install() {
        // The model value is the resting figure, so a layer whose animation has not arrived yet
        // draws the mark at the strength it would rest at. Written with actions off, or AppKit
        // interpolates its way there.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = Float(BusyBreath.restingOpacity)
        CATransaction.commit()

        guard let layer else { return }
        install(breath(), on: layer, key: "breathe", beginAt: epoch)
    }

    /// One whole breath, sampled.
    ///
    /// Keyframes rather than a timing function, because the envelope's two eased stretches are
    /// power curves and Core Animation's timing functions are cubic beziers: fitting them would be
    /// an approximation of an approximation. `BusyBreath` is where the shape lives and where it is
    /// tested, and it hands out the samples for exactly this.
    ///
    /// Capped at the frame rate `PulsingDot` measured for its own fade: this is a fade with no
    /// position in it, over three seconds, so twelve frames a second moves it about a fiftieth of
    /// its range per frame.
    private func breath() -> CAKeyframeAnimation {
        let samples = BusyBreath.opacitySamples(count: 24)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = samples
        animation.keyTimes = (0..<samples.count).map {
            NSNumber(value: Double($0) / Double(samples.count - 1))
        }
        animation.calculationMode = .linear
        animation.duration = BusyBreath.period
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        return animation
    }
}
