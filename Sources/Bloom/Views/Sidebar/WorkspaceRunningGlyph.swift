import SwiftUI
import QuartzCore
import BloomCore

/// The mark at the head of a sidebar row whose agent is mid turn.
///
/// Three dots in a vertical line, brightening and dimming in turn so the light runs down them and
/// back. It is Conductor's mark for the same state, in Bloom's own glyph box and Bloom's own
/// accent, and it is the only thing in the sidebar that moves.
///
/// It REPLACES the pulsing `ActivityDot` that used to stand here rather than joining it. Both
/// occupy the row's one glyph slot, so keeping both was never on the table, and of the two this is
/// the one that says which agent is working without also being the shape the app uses for "a thing
/// is happening" in four other places. The row now has one moving part, not two, and the tab strip
/// and the transcript keep the dot they always had.
///
/// The row cannot shift when the state changes. `WorkspaceStatusGlyph` frames every one of its
/// thirteen marks in the same `Metrics.glyph` box, this one included, and the figure is centred in
/// it: a workspace that starts working, finishes, and comes back with changed files draws three
/// different shapes in the same square and the name beside it never moves a pixel. Measured on a
/// capture: the name begins on the same pixel in a running row and an idle one.
///
/// # Why the dots do not step
///
/// The first version of this built a figure out of nothing, a stage per beat: one dot, then a line
/// of three, then a grid of six. It was wrong, and wrong in a way worth writing down, because it
/// reads perfectly well in the source and cannot look right on a screen. Swapping between three
/// arrangements gives exactly three frames of motion however often the swap fires, and shortening
/// the interval only makes the three arrivals come sooner. It was read as "like 3 frames" from
/// across the room, which is precisely what it was.
///
/// So nothing here is stepped. Each dot holds one opacity, ramped between two values, and Core
/// Animation interpolates it at whatever the display refreshes at: 120 frames a second on a
/// ProMotion panel and 60 on anything else, with no rate named anywhere here.
///
/// The travel is `stagger`. Every dot runs the same wave, each starting a little after the one
/// above it, so at any instant the three are at three different points of it and the brightness
/// runs down the line. Without it the three would brighten together, which is a blink.
///
/// # The phase is not this view's
///
/// Every one of these reads `BusyPulse.epoch` rather than starting a loop of its own, which is the
/// whole argument on that type: five agents started at five moments give five figures at five
/// phases, and nothing ever pulls them back together. Phased off one instant, five lit rows are
/// one rhythm down the column, and they are in step with the light on the rule as well, because
/// the sweep is exactly four of these.
///
/// # What it costs
///
/// Three `CAKeyframeAnimation`s per running row, added when the row starts working and never
/// touched again, and one body evaluation in the same period. The list is an `NSTableView`
/// underneath, so a running row scrolled out of view is not built and holds nothing.
///
/// It used to be three SwiftUI opacity animations restarted every 750 milliseconds off a shared
/// tick, and those are not the same thing: SwiftUI runs such an animation itself, on the main
/// thread, and re-renders the display list of the whole sidebar for each frame of it. That is why
/// five lit rows cost barely more than one, and why three 3 point dots cost as much as a 160 point
/// light crossing the window. See `BusyPulse`.
///
/// The clock stops when the window is not the front one and when Reduce Motion is on, and the
/// figure then rests at full strength, which is the state the mark means anyway.
struct WorkspaceRunningGlyph: View {
    /// Set on a row sitting on the accent selection fill, where the accent itself is unreadable.
    var isOnSelection = false

    private var pulse: BusyPulse { .shared }

    /// The figure: three dots, three points across and one point apart.
    ///
    /// Whole points, and that is the only reason these are not 2.5 and 2. Eleven points centred in
    /// the thirteen point glyph box puts every dot on a whole point, so the figure is drawn on
    /// pixel boundaries at one times as well as at two. The half point version measured 11.5 in a
    /// 13 box, which lands the first dot on 0.75 and softens all three on a display that has no
    /// half pixels to soften them into.
    static let dot: CGFloat = 3
    static let gap: CGFloat = 1
    static let count = 3

    /// How tall the whole figure is: three dots and the two gaps between them.
    static var height: CGFloat { CGFloat(count) * dot + CGFloat(count - 1) * gap }

    /// How far each dot's ramp trails the one above it. Long enough that the eye reads a direction
    /// rather than three dots moving as one, short enough that the last dot has finished before
    /// the next beat begins: two of these plus `ramp` is `BusyPulse.beat` to the millisecond.
    static let stagger: CFTimeInterval = 0.1

    /// How long one dot takes to cross between its two opacities.
    static let ramp: CFTimeInterval = 0.55

    /// What a dot holds at the bottom of its ramp. Not zero: a dot that goes out entirely makes
    /// the figure a different shape twice a beat, and the shape is what this column is read by.
    static let dim: Double = 0.22

    private var tint: Color { isOnSelection ? Palette.textInverted : Palette.running }

    var body: some View {
        if pulse.isTicking {
            // Layers rather than views, and only here. The resting figure below stays SwiftUI,
            // because it is the one `ImageRenderer` can draw and because a still figure has
            // nothing to gain from Core Animation. See `Snapshot`.
            RunningDots(epoch: pulse.epoch, tint: NSColor(tint))
                .frame(width: Self.dot, height: Self.height)
        } else {
            VStack(spacing: Self.gap) {
                ForEach(0..<Self.count, id: \.self) { _ in
                    Circle()
                        .fill(tint)
                        .frame(width: Self.dot, height: Self.dot)
                }
            }
        }
    }
}

// MARK: - The figure

/// The moving figure: three dot layers running one wave, each a little behind the one above it.
private struct RunningDots: NSViewRepresentable {
    /// The heartbeat's start, which is the only thing that decides where in its wave the figure
    /// is. See `BusyPulse.epoch`.
    var epoch: CFTimeInterval

    /// Resolved by the caller, because which of the two tints a row wants is a question about the
    /// row's selection rather than about the figure.
    var tint: NSColor

    func makeNSView(context: Context) -> RunningDotsView {
        let view = RunningDotsView(frame: .zero)
        view.configure(epoch: epoch, tint: tint)
        return view
    }

    func updateNSView(_ view: RunningDotsView, context: Context) {
        view.configure(epoch: epoch, tint: tint)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RunningDotsView, context: Context) -> CGSize? {
        CGSize(width: WorkspaceRunningGlyph.dot, height: WorkspaceRunningGlyph.height)
    }
}

/// Three round layers, each under a repeating keyframe animation on its opacity.
final class RunningDotsView: BusyPulseLayerView {
    private var dots: [CALayer] = []
    private var epoch: CFTimeInterval = 0
    private var tint: NSColor = .clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The parent clips, and the figure is exactly its own size, so nothing here would ever be
        // clipped. Off anyway, because a mask on eleven points of layer is a rasterisation nobody
        // asked for.
        layer?.masksToBounds = false

        let size = WorkspaceRunningGlyph.dot
        for _ in 0..<WorkspaceRunningGlyph.count {
            let dot = CALayer()
            dot.cornerRadius = size / 2
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }

    /// The three dots, stacked from the top of the box down. `isFlipped` is what makes that read
    /// the same way here as it does in the `VStack` this replaces: the first dot is the top one,
    /// and the light runs down the line from it.
    override func layout() {
        super.layout()
        let size = WorkspaceRunningGlyph.dot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(
                x: 0,
                y: CGFloat(index) * (size + WorkspaceRunningGlyph.gap),
                width: size,
                height: size
            )
        }
        CATransaction.commit()
    }

    override func applyColors() {
        let color = resolved(tint)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots { dot.backgroundColor = color }
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
        for (index, dot) in dots.enumerated() {
            install(wave(), on: dot, key: "wave", beginAt: epoch + Double(index) * WorkspaceRunningGlyph.stagger)
        }
    }

    /// One whole wave of a single dot, written out rather than left to a basic animation, because
    /// a dot does not spend the whole beat moving.
    ///
    /// It ramps up over `ramp`, holds at full strength until the beat is out, ramps back down over
    /// `ramp`, and holds dim until the next beat. That hold is what a `CABasicAnimation` with
    /// `autoreverses` could not have given: it would have spread each ramp over the whole 750
    /// milliseconds and the figure would breathe rather than pulse. These are the same four
    /// stretches the SwiftUI version drew, with the same curve on the two that move, so the motion
    /// on screen is the motion that was there before.
    private func wave() -> CAKeyframeAnimation {
        let beat = BusyPulse.beat
        let cycle = BusyPulse.wave
        let ramp = WorkspaceRunningGlyph.ramp
        let dim = WorkspaceRunningGlyph.dim

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [dim, 1, 1, dim, dim]
        animation.keyTimes = [0, ramp / cycle, beat / cycle, (beat + ramp) / cycle, 1]
            .map { NSNumber(value: $0) }
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
        ]
        animation.duration = cycle
        return animation
    }
}
