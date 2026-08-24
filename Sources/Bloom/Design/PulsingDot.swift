import SwiftUI
import QuartzCore
import BloomCore

/// The dot that says an agent is working, wherever the window says it.
///
/// One implementation for all three: `ActivityDot` in the transcript and on a tab, and
/// `WorkspaceRunningGlyph` at the head of a sidebar row. The sidebar used to draw a pair of
/// breathing rings instead, and a window that says the same thing in two shapes is a window that
/// has to be learned twice. `BusyDot` holds the envelope, and this turns it into a layer.
///
/// # Why it is a layer and not a `repeatForever`
///
/// It was a SwiftUI `.easeInOut.repeatForever(autoreverses:)`, and that is the expensive way to
/// move three points of ink. SwiftUI does not hand such an animation to the render server: it
/// interpolates on the main thread and re-renders the hosting view's display list every frame, so
/// the bill is set by the size of the window rather than by the size of the mark. `BusyPulse`'s
/// header carries the measurement, taken on this app: 320,971 view graph updates for 12 body
/// evaluations over 12.3 seconds, with `RootGeometry` and `LayoutChildGeometries` recomputed 239.6
/// times a second.
///
/// That cost is why the dot used to stop when the window went behind another app, and stopping was
/// the wrong half of the problem to fix: a mark that says "this is still running" is at its most
/// useful in a window somebody has left to one side. A `CAAnimation` on a layer is interpolated in
/// the render server on the display's own clock, so the app is not woken for a frame of it, and
/// nothing is saved by parking it. It runs whether or not the window is in front, and `Reduce
/// Motion` is the one thing that still holds it still. See `BusyPulseDriver`.
struct PulsingDot: View {
    /// How wide the dot is at rest. It swells past this by a third at the top of the pulse, which
    /// is why every call site centres it in a box with room to spare.
    var diameter: CGFloat

    /// Resolved by the caller, because which tint a mark wants is a question about where it is
    /// drawn: a sidebar row on the accent selection fill cannot use the accent.
    var tint: Color

    /// False for a dot that is present but idle, which is the tab strip's grey one. It draws the
    /// resting figure whatever the heartbeat is doing.
    var isMoving = true

    private var pulse: BusyPulse { .shared }

    var body: some View {
        if isMoving && pulse.isTicking {
            // A layer rather than a view, and the resting figure below is deliberately not one.
            // Only the moving state has anything to gain from Core Animation, and keeping the
            // still one in SwiftUI is what lets `ImageRenderer` photograph a mark that is not
            // pulsing. See `Snapshot`, which cannot draw an `NSViewRepresentable` at all.
            PulsingDotLayer(epoch: pulse.epoch, diameter: diameter, tint: NSColor(tint))
                .frame(width: diameter, height: diameter)
        } else {
            Circle()
                .fill(tint.opacity(BusyDot.opacity(at: BusyDot.resting)))
                .frame(
                    width: diameter * BusyDot.scale(at: BusyDot.resting),
                    height: diameter * BusyDot.scale(at: BusyDot.resting)
                )
        }
    }
}

// MARK: - The dot beside a word

/// The busy dot where it sits next to text: beside "Requesting" and "Working" in the transcript,
/// and in front of the label of a tab whose agent is mid turn.
///
/// It has an idle state, which `WorkspaceRunningGlyph` has no use for: a tab keeps its dot when
/// nothing is running and draws it grey, because the mark going missing would move the label.
/// `Metrics.dot` is sized to sit on a text baseline, which is why the sidebar's copy is wider.
///
/// It used to hold the whole animation itself, along with a frontmost gate and a `@State` flag to
/// take a `repeatForever` back down when the window went behind. All three are gone: what decides
/// whether anything moves is `BusyPulseDriver`, in one place, and what moves is a layer.
struct ActivityDot: View {
    var isActive: Bool
    var tint: Color = Palette.running

    var body: some View {
        PulsingDot(
            diameter: Metrics.dot,
            tint: isActive ? tint : Palette.textTertiary,
            isMoving: isActive
        )
    }
}

// MARK: - The moving figure

private struct PulsingDotLayer: NSViewRepresentable {
    /// The heartbeat's start, which is the only thing that decides where in its pulse the dot is.
    /// See `BusyPulse.epoch`.
    var epoch: CFTimeInterval

    var diameter: CGFloat

    var tint: NSColor

    func makeNSView(context: Context) -> PulsingDotView {
        let view = PulsingDotView(frame: .zero)
        view.configure(epoch: epoch, diameter: diameter, tint: tint)
        return view
    }

    func updateNSView(_ view: PulsingDotView, context: Context) {
        view.configure(epoch: epoch, diameter: diameter, tint: tint)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulsingDotView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

/// One filled circle on a layer, under a repeating scale and a repeating fade.
final class PulsingDotView: BusyPulseLayerView {
    private let dot = CAShapeLayer()
    private var epoch: CFTimeInterval = 0
    private var diameter: CGFloat = 0
    private var tint: NSColor = .clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The dot is laid out at its resting size and grows past it by a sixth of its width on
        // each side. Clipped, it would flatten against the edges of its own box instead of
        // swelling, and a mask on six points of layer is a rasterisation nobody asked for.
        layer?.masksToBounds = false
        dot.strokeColor = nil
        // The path is centred on the layer's own origin, so scaling it scales about the centre of
        // the figure without any anchor arithmetic.
        dot.bounds = .zero
        layer?.addSublayer(dot)
    }

    override func layout() {
        super.layout()
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = centre
        CATransaction.commit()
    }

    override func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.fillColor = resolved(tint)
        CATransaction.commit()
    }

    /// Guarded, because `updateNSView` runs whenever the view around it is rebuilt, which in a
    /// sidebar scrolling under the pointer is often. Reinstalling an animation that is already
    /// correct would also reset its phase, and the phase is the whole point.
    func configure(epoch: CFTimeInterval, diameter: CGFloat, tint: NSColor) {
        if tint != self.tint {
            self.tint = tint
            applyColors()
        }
        if diameter != self.diameter {
            self.diameter = diameter
            rebuildPath()
        }
        guard epoch != self.epoch else { return }
        self.epoch = epoch
        install()
    }

    /// The circle is built at the widest it will ever be and scaled down from there, never up. See
    /// `BusyDot.drawnScale`.
    private func rebuildPath() {
        let radius = diameter * BusyDot.drawnScale / 2
        dot.path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
            transform: nil
        )
    }

    private func install() {
        // The model values are the resting figure, so a layer whose animation has not arrived yet
        // draws the mark at the size it would rest at rather than at the size its path was baked
        // at. Written with actions off, or AppKit interpolates its way there.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let resting = BusyDot.pathScale(at: BusyDot.resting)
        dot.transform = CATransform3DMakeScale(resting, resting, 1)
        dot.opacity = Float(BusyDot.opacity(at: BusyDot.resting))
        CATransaction.commit()

        install(
            pulse("transform.scale", from: BusyDot.pathScale(at: 0), to: BusyDot.pathScale(at: 1)),
            on: dot, key: "swell", beginAt: epoch
        )
        install(
            pulse("opacity", from: BusyDot.opacity(at: 0), to: BusyDot.opacity(at: 1)),
            on: dot, key: "fade", beginAt: epoch
        )
    }

    /// Half a pulse, played forwards and then backwards forever.
    ///
    /// `easeInEaseOut` and `autoreverses` rather than a keyframed envelope, because this envelope
    /// *is* a cubic ease and Core Animation's timing functions are cubic beziers. `BusyBreath` is
    /// sampled instead only because its two eased stretches are power curves, which a bezier could
    /// approximate and not express. `easeInEaseOut` is symmetric in time, so the return leg is the
    /// same curve rather than a different one run backwards, and the dot is momentarily still at
    /// each end of its travel.
    ///
    /// Capped, and it can afford to be: the dot travels a sixth of its own width, so at twelve
    /// frames a second its edge moves about a quarter of a point per frame, which is inside the
    /// softness of a resampled circle. The fade it moves with has no position to stutter at all.
    private func pulse(_ keyPath: String, from: Double, to: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = BusyDot.period / 2
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.autoreverses = true
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        return animation
    }
}
