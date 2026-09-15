import SwiftUI
import QuartzCore
import BloomCore

/// The moving half of a busy sweep: one gradient layer carried across a clipped plate by the render
/// server.
///
/// # Why layers, again
///
/// The shimmer before this was a SwiftUI `TimelineView` at thirty frames a second, and its own note
/// recorded what that class of animation costs in this window: `ActivityRule` measured a SwiftUI
/// driven rule at 2.96 seconds of CPU every 15 on a 120Hz panel, against 0.13 for the same figure
/// on Core Animation layers, because a SwiftUI frame re-renders the hosting view's display list
/// rather than the mark's. The sweep is a gradient that moves and nothing else, which is the case
/// Core Animation exists for, so it is handed one repeating animation when a turn starts and left
/// alone. The application process is not woken for a frame of it. Several busy tabs are several
/// animations the render server interpolates together, all begun from one instant (`epoch`), so
/// they cross in step and none of them costs the main thread anything while it moves.
///
/// # Why a resize does not restart it
///
/// What is animated is the band layer's `anchorPoint`, not its position. The band is positioned at
/// the track's leading edge and sized to its share of the track, and an anchor is measured in the
/// band's own widths, so the same two anchor values move the band across any width. A window being
/// dragged wider, a strip gaining a tab, or a tab lifted and carried changes the layers' frames in
/// `layout()` and never touches the animation. `BusySweep.Band.anchor(atLeadingEdge:)` has the
/// arithmetic and `BusySweepTests` holds it.
///
/// # Arriving and leaving
///
/// The plate's opacity fades over `BusySweep.fade`, as a layer animation as well. A turn that ends
/// fades the band out while it carries on across, from whatever opacity it had reached, so a stop
/// halfway through arriving goes out from there rather than jumping. When the fade has finished the
/// sweep animation is removed, so an idle tab has no layer animation at all, and `onFadedOut` tells
/// the SwiftUI side it can take this view away. A view that appears already busy, a strip arriving
/// mid turn, is lit from its first frame: that is not a turn starting.
final class BusySweepView: BusyPulseLayerView {
    /// The shared start of every sweep, so two tabs that went busy at different moments are at the
    /// same point in their crossings. Taken once, the first time any sweep is drawn; a `beginTime`
    /// in the past is exactly what puts a late arrival mid stride. See `BusyPulseLayerView.install`.
    private static let epoch = CACurrentMediaTime()

    /// `BusySweep.frameRate`, as the range the render server is offered.
    private static let frameRate = CAFrameRateRange(
        minimum: 30, maximum: Float(BusySweep.frameRate), preferred: Float(BusySweep.frameRate)
    )

    private static let sweepKey = "sweep"
    private static let fadeKey = "fade"

    /// Clips the band to the figure's shape and carries the fade. A sublayer rather than the view's
    /// own layer, because SwiftUI owns the hosting layer's opacity and would write over a fade put
    /// there.
    private let plate = CALayer()
    private let band = CAGradientLayer()

    private var figure: BusySweepFigure = .tab
    private var isActive = false
    /// Bumped on every start and stop, so the completion of a fade that has since been reversed
    /// cannot remove the sweep from under a turn that started again.
    private var generation = 0

    /// Called once a stop has finished fading out and nothing is left to draw.
    var onFadedOut: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        plate.masksToBounds = true
        plate.opacity = 0
        plate.addSublayer(band)
        layer?.addSublayer(plate)
        applyColors()
    }

    // MARK: Configuration

    /// Guarded, because `updateNSView` runs on every pass SwiftUI makes over this view and a strip
    /// being resized or a tab being carried makes a great many of them.
    func configure(figure: BusySweepFigure, isActive: Bool, arrivesLit: Bool) {
        if figure != self.figure {
            self.figure = figure
            applyColors()
            needsLayout = true
        }
        guard isActive != self.isActive || band.animation(forKey: Self.sweepKey) == nil && isActive else {
            return
        }
        self.isActive = isActive
        generation += 1
        if isActive {
            if band.animation(forKey: Self.sweepKey) == nil { installSweep() }
            fade(to: 1, animated: !arrivesLit, then: nil)
        } else {
            let stopping = generation
            fade(to: 0, animated: true) { [weak self] in
                // A turn later rather than inline. A stop that finds the plate already dark adds no
                // animation, and the completion can then run inside the `updateNSView` that asked
                // for the stop, where taking this view away would write SwiftUI state mid update.
                Task { @MainActor [weak self] in
                    guard let self, self.generation == stopping else { return }
                    self.band.removeAnimation(forKey: Self.sweepKey)
                    self.onFadedOut?()
                }
            }
        }
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds
        // A tab's capsule is a circular capsule (`Capsule()`), so its radius is half its height. The
        // column's plate is the column itself and square; the segment rounds its own ends instead.
        plate.cornerRadius = figure == .tab ? bounds.height / 2 : 0
        let shape = figure.band
        band.bounds = CGRect(x: 0, y: 0, width: bounds.width * shape.widthShare, height: bounds.height)
        band.position = CGPoint(x: 0, y: bounds.height / 2)
        band.cornerRadius = figure == .column ? bounds.height / 2 : 0
        CATransaction.commit()
    }

    // MARK: Colour

    override func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fill = resolved(Palette.accentFillNSColor)
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // The column's segment is the house fill undiluted at its middle, in both appearances: it
        // clears the non-text floor on the dark window as it is. The tab's band is a tint, and its
        // dark member is stronger for the reason `BusySweep.Strength` gives.
        let peak = figure == .tab ? BusySweep.tabBand.member(dark: isDark) : 1
        let shape = figure.band
        band.colors = shape.stops.map { fill.copy(alpha: peak * $0.strength) ?? fill }
        band.locations = shape.stops.map { NSNumber(value: $0.location) }
        CATransaction.commit()
    }

    // MARK: Animation

    private func installSweep() {
        let shape = figure.band
        // The model value is the start of a crossing, wholly off the leading edge, so a band whose
        // animation has gone draws nothing rather than parking itself across the tab.
        let from = shape.anchor(atLeadingEdge: shape.leadingFrom)
        let to = shape.anchor(atLeadingEdge: shape.leadingTo)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.anchorPoint = CGPoint(x: from, y: 0.5)
        CATransaction.commit()

        let sweep = CABasicAnimation(keyPath: "anchorPoint")
        sweep.fromValue = NSValue(point: NSPoint(x: from, y: 0.5))
        sweep.toValue = NSValue(point: NSPoint(x: to, y: 0.5))
        sweep.duration = BusySweep.period
        let curve = BusySweep.curve
        sweep.timingFunction = CAMediaTimingFunction(
            controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2)
        )
        sweep.preferredFrameRateRange = Self.frameRate
        install(sweep, on: band, key: Self.sweepKey, beginAt: Self.epoch)
    }

    /// Moves the plate's opacity to `target`, from wherever it is on screen right now.
    ///
    /// The duration is the share of a full fade still to go, so a reversal halfway through takes
    /// half as long and the light moves at one speed whichever way it is going.
    private func fade(to target: Float, animated: Bool, then completion: (@MainActor () -> Void)?) {
        let current = plate.presentation()?.opacity ?? plate.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let completion {
            // Core Animation calls this on the main thread once the animations added inside this
            // transaction have finished, or at once if none were.
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        }
        plate.removeAnimation(forKey: Self.fadeKey)
        plate.opacity = target
        if animated, current != target {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = current
            fade.toValue = target
            fade.duration = BusySweep.fade * Double(abs(target - current))
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            plate.add(fade, forKey: Self.fadeKey)
        }
        CATransaction.commit()
    }
}

/// Which of the two sweeps a `BusySweepView` draws.
enum BusySweepFigure: Equatable {
    /// The band through a busy tab's capsule.
    case tab
    /// The segment along the top of a column with no strip.
    case column

    var band: BusySweep.Band {
        switch self {
        case .tab: BusySweep.tab
        case .column: BusySweep.column
        }
    }
}

/// `BusySweepView` for SwiftUI. Mounted only while a sweep is running or fading out; see
/// `BusySweepBand`, which decides that.
struct BusySweepLayer: NSViewRepresentable {
    var figure: BusySweepFigure
    var isActive: Bool
    /// Whether the first frame is already lit, for a view that appears mid turn.
    var arrivesLit: Bool
    var onFadedOut: @MainActor () -> Void

    func makeNSView(context: Context) -> BusySweepView {
        let view = BusySweepView(frame: .zero)
        view.onFadedOut = onFadedOut
        view.configure(figure: figure, isActive: isActive, arrivesLit: arrivesLit)
        return view
    }

    func updateNSView(_ view: BusySweepView, context: Context) {
        view.onFadedOut = onFadedOut
        view.configure(figure: figure, isActive: isActive, arrivesLit: false)
    }

    /// Fills whatever it is given and asks for nothing, so a tab's width stays the strip's to give.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BusySweepView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
