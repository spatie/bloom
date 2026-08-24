import SwiftUI
import QuartzCore
import BloomCore

/// The mark at the head of a sidebar row whose agent is mid turn.
///
/// Two concentric rings whose radial gap breathes: the inner grows while the outer shrinks until
/// they almost meet, then they part again. It is the only thing in the sidebar that moves.
///
/// It replaced three dots that ran a wave of opacity down a vertical line, and the reason is worth
/// keeping. Seventeen candidates were drawn side by side in a browser at true size in a mock row,
/// and the three that read best at thirteen points all moved slowly. At this size a single element
/// changing is a dot getting bigger; two elements approaching each other is a gesture, and a
/// gesture survives being small. The dots' own advantage is real and was given up knowingly: an
/// opacity crossfade has no position to stutter, so it was immune to frame capping in a way nothing
/// positional is. This is capped instead, and the cap is affordable because the travel is tiny.
///
/// The row cannot shift when the state changes. `WorkspaceStatusGlyph` frames every one of its
/// marks in the same `Metrics.glyph` box, this one included, and the figure is centred in it: a
/// workspace that starts working, finishes, and comes back with changed files draws three different
/// shapes in the same square and the name beside it never moves a pixel.
///
/// # The phase is not this view's
///
/// It reads `BusyPulse.epoch` rather than starting a loop of its own, which is the whole argument on
/// that type: five agents started at five moments give five figures at five phases, and nothing ever
/// pulls them back together. Phased off one instant, five working rows breathe as one column, and
/// they are in step with the light on the rule as well, because `BusyBreath.period` is exactly one
/// crossing of it. See `BusyBreath.period` for why the design's 3.6 seconds was not kept.
///
/// # What it costs
///
/// Two layers per working row and three `CAKeyframeAnimation`s, added when the row starts working
/// and never touched again. Nothing here rasterises a path per frame: each ring's path is built once
/// at the largest radius it will ever hold and then scaled down, so the render server is
/// interpolating a transform and an opacity and nothing else. That matters because a sidebar can
/// show many working rows at once, and per row cost multiplies where the window's does not.
///
/// A stroked ring that is scaled is resampled, so its stroke is only ever as wide as its scale. Each
/// ring is baked at the largest radius it will hold and scaled down, so **a ring is thinnest when it
/// is smallest**, which is the opposite way round from the note the design was drawn with. Measured
/// on a capture at eight times rather than reasoned about: the inner ring is about half a point at
/// rest and a whole point at the top of the breath.
///
/// Kept, rather than corrected. Holding the stroke at a point would mean animating `lineWidth`, and
/// that re-renders a shape layer's contents every frame, which is the one cost this mark is built to
/// avoid. What it buys instead is that the inner ring brightens as it opens, so the figure gains
/// weight as it tightens and the pair never reads as a fixed target with something moving inside it.
///
/// The clock stops when the window is not the front one and when Reduce Motion is on, and the figure
/// then rests half open, which is two clean concentric rings and a good mark in its own right.
struct WorkspaceRunningGlyph: View {
    /// Set on a row sitting on the accent selection fill, where the accent itself is unreadable.
    var isOnSelection = false

    private var pulse: BusyPulse { .shared }

    /// The box the figure is centred in. The outer ring is 11.2 points across at its widest and its
    /// stroke is a point, so 13 is the smallest whole number that cannot clip it, and it is the box
    /// every other mark in this column already uses.
    static let box: CGFloat = Metrics.glyph

    /// How wide a ring is drawn. One point, and not scaled with anything: a hairline ring at this
    /// size reads as a smudge on a non retina display, and two points closes the gap the figure is
    /// made of.
    static let line: CGFloat = 1

    /// Where the figure rests when nothing is moving. Half way, so both rings are visible and
    /// neither is at an extreme, which is the still the design was chosen with.
    static let restingBreath: Double = 0.5

    private var tint: Color { isOnSelection ? Palette.textInverted : Palette.running }

    var body: some View {
        if pulse.isTicking {
            // Layers rather than views, and only here. The resting figure below stays SwiftUI,
            // because it is the one `ImageRenderer` can draw and because a still figure has
            // nothing to gain from Core Animation. See `Snapshot`.
            BreathingRings(epoch: pulse.epoch, tint: NSColor(tint))
                .frame(width: Self.box, height: Self.box)
        } else {
            RestingRings(tint: tint)
                .frame(width: Self.box, height: Self.box)
        }
    }
}

// MARK: - The resting figure

/// The two rings held half open, drawn in SwiftUI so an offscreen render can photograph them.
private struct RestingRings: View {
    var tint: Color

    var body: some View {
        let breath = WorkspaceRunningGlyph.restingBreath
        let inner = BusyBreath.Rings.innerScale(at: breath) * BusyBreath.Rings.innerDrawn
        let outer = BusyBreath.Rings.outerScale(at: breath) * BusyBreath.Rings.outerDrawn

        ZStack {
            Circle()
                .stroke(tint.opacity(BusyBreath.Rings.outerOpacity(at: breath)), lineWidth: WorkspaceRunningGlyph.line)
                .frame(width: outer * 2, height: outer * 2)
            Circle()
                .stroke(tint.opacity(BusyBreath.Rings.innerOpacity), lineWidth: WorkspaceRunningGlyph.line)
                .frame(width: inner * 2, height: inner * 2)
        }
    }
}

// MARK: - The moving figure

private struct BreathingRings: NSViewRepresentable {
    /// The heartbeat's start, which is the only thing that decides where in its breath the figure
    /// is. See `BusyPulse.epoch`.
    var epoch: CFTimeInterval

    /// Resolved by the caller, because which of the two tints a row wants is a question about the
    /// row's selection rather than about the figure.
    var tint: NSColor

    func makeNSView(context: Context) -> BreathingRingsView {
        let view = BreathingRingsView(frame: .zero)
        view.configure(epoch: epoch, tint: tint)
        return view
    }

    func updateNSView(_ view: BreathingRingsView, context: Context) {
        view.configure(epoch: epoch, tint: tint)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BreathingRingsView, context: Context) -> CGSize? {
        CGSize(width: WorkspaceRunningGlyph.box, height: WorkspaceRunningGlyph.box)
    }
}

/// Two ring layers, each under a repeating keyframe animation on its scale.
final class BreathingRingsView: BusyPulseLayerView {
    private let inner = CAShapeLayer()
    private let outer = CAShapeLayer()
    private var epoch: CFTimeInterval = 0
    private var tint: NSColor = .clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The rings are exactly the box, so nothing here would ever be clipped, and a mask on
        // thirteen points of layer is a rasterisation nobody asked for.
        layer?.masksToBounds = false

        for (ring, radius) in [(outer, BusyBreath.Rings.outerDrawn), (inner, BusyBreath.Rings.innerDrawn)] {
            ring.fillColor = nil
            ring.lineWidth = WorkspaceRunningGlyph.line
            ring.path = CGPath(
                ellipseIn: CGRect(
                    x: -radius, y: -radius, width: radius * 2, height: radius * 2
                ),
                transform: nil
            )
            // The path is centred on the layer's own origin, so scaling it scales about the centre
            // of the figure without any anchor arithmetic.
            ring.bounds = .zero
            layer?.addSublayer(ring)
        }
    }

    override func layout() {
        super.layout()
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inner.position = centre
        outer.position = centre
        CATransaction.commit()
    }

    override func applyColors() {
        let color = resolved(tint)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inner.strokeColor = color
        outer.strokeColor = color
        inner.opacity = Float(BusyBreath.Rings.innerOpacity)
        CATransaction.commit()
    }

    /// Guarded, because `updateNSView` runs whenever the row around it is rebuilt, which in a
    /// sidebar scrolling under the pointer is often. Reinstalling an animation that is already
    /// correct would also reset its phase, and the phase is the whole point.
    func configure(epoch: CFTimeInterval, tint: NSColor) {
        if tint != self.tint {
            self.tint = tint
            applyColors()
        }
        guard epoch != self.epoch else { return }
        self.epoch = epoch
        install()
    }

    private func install() {
        let breath = BusyBreath.samples()
        install(
            keyframes("transform.scale", breath.map { BusyBreath.Rings.innerScale(at: $0) }),
            on: inner, key: "breath", beginAt: epoch
        )
        install(
            keyframes("transform.scale", breath.map { BusyBreath.Rings.outerScale(at: $0) }),
            on: outer, key: "breath", beginAt: epoch
        )
        install(
            keyframes("opacity", breath.map { BusyBreath.Rings.outerOpacity(at: $0) }),
            on: outer, key: "weight", beginAt: epoch
        )
    }

    /// One whole breath, sampled rather than shaped by timing functions. See
    /// `BusyBreath.samples(count:)` for why.
    ///
    /// Capped, and this mark can afford to be where the dots before it could not have been. The
    /// inner ring travels 1.7 points over an inhale of just under a second, so at twelve frames a
    /// second it moves about a seventh of a point per frame, which is inside the softness of a
    /// resampled one point stroke. `BrandBranching` names the same range for the same reason. The
    /// dots this replaced named no rate at all, deliberately, because an opacity crossfade has
    /// nothing to stutter and no reason to be slowed.
    private func keyframes(_ keyPath: String, _ values: [Double]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = BusyBreath.period
        animation.calculationMode = .linear
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        return animation
    }
}
