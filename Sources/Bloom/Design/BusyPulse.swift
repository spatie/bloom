import SwiftUI
import QuartzCore
import BloomCore

/// The window's one heartbeat, while an agent is working.
///
/// Everything that moves while agents are running reads its phase from here: the shared rule under
/// the title bar, which carries a crest along its whole width (`ActivityRule`), the dot at the
/// head of every working row in the sidebar (`WorkspaceRunningGlyph`), and the same dot beside
/// "Working" in the transcript and in front of a running tab's label (`ActivityDot`). None of them
/// starts an animation of its own, and that is the whole reason this type exists.
///
/// An animation begins when the view that carries it is committed. Five agents started at five
/// different moments therefore give five row figures at five different phases, which is not a
/// rhythm, it is five things blinking at a column of names. Worse, they never converge: nothing
/// pulls two free running loops back together. One instant that every mark measures its phase
/// from means an agent started ten seconds after the last one is in step with it on its first
/// frame, and it means the rule and the rows are in step with each other as well, so the window
/// has one heartbeat rather than two that drift past each other.
///
/// # What this used to be, and why it is not that any more
///
/// It used to be a counter. A `Task` woke every 750 milliseconds, advanced a tick, and published
/// two booleans; each mark carried a SwiftUI `.animation(_:value:)` keyed on one of them, so every
/// beat restarted an interpolation that SwiftUI then ran itself.
///
/// That is what made the two marks expensive, and it was measured rather than argued. Instruments'
/// SwiftUI template, 12.3 seconds of a window with five agents running: 320,971 view graph
/// updates, of which **12** were view body evaluations. The bodies were not the cost. The cost was
/// `RootGeometry`, `LayoutChildGeometries` and the display list items under them, recomputed 239.6
/// times a second, which on a 120Hz panel is twice a frame, every frame. SwiftUI does not hand an
/// `.animation(_:value:)` to the render server: it interpolates on the main thread and re-renders
/// the display list of the whole hosting view each time it does. The bill is therefore set by how
/// big the window is, not by how big the mark is, which is exactly what the numbers said: a 160
/// point gradient crossing 1394 points cost the same as three 3 point dots fading, and five lit
/// rows cost barely more than one.
///
/// So nothing is stepped and nothing is interpolated here any more. What this publishes is one
/// number, `epoch`: the `CACurrentMediaTime()` at which the current run of the heartbeat began.
/// Every mark builds a repeating `CAAnimation` whose `beginTime` is derived from it, hands it to a
/// layer, and never hears from it again. Core Animation runs the interpolation out of process, the
/// app is not woken per frame, and the phase lock is stronger than it was: two animations that
/// share an absolute `beginTime` and have periods in a whole number ratio cannot drift, where two
/// restarted from a timer could only be as accurate as the timer.
///
/// The periods stay in that ratio, and each of them lives with the mark it belongs to rather than
/// here: `BusyDot.period` is a second and a half, `BusyCrest.wavePeriod` takes that same number and
/// `BusyCrest.period` is three, which is two of those and is also `BusyBreath.period`. So the crest
/// leaves the rule on a frame where every dot in the window is at the top of its swell. There were
/// four constants here describing the figure of the light that used to travel the rule (a crossing
/// was three seconds and out and back was six), and they went with the light: see `ActivityRule`
/// for the two figures that have replaced it since, and `10bef55` for the measurement that
/// established the ratio.
///
/// It runs while something is running, and it does not care whether the window is in front. See
/// `BusyPulseDriver`, which is the single place that decides.
@MainActor
@Observable
final class BusyPulse {
    static let shared = BusyPulse()

    /// Whether the heartbeat is running at all.
    ///
    /// False is not the same as idle. An agent can be working with this false, because Reduce
    /// Motion is on, and every mark has a resting state for exactly that: the rule holds a quiet
    /// tint and a row holds a whole dot. So what this answers is "is anything moving", and the
    /// marks ask `AppModel` itself whether anything is running.
    private(set) var isTicking = false

    /// The instant the current run of the heartbeat began, on Core Animation's clock.
    ///
    /// Every mark's animation is phased off this and nothing else, which is what puts them on one
    /// heartbeat. A row that appears ten seconds into a run reads the same number the first row
    /// read and lands mid stride beside it, because a repeating `CAAnimation` whose `beginTime` is
    /// already in the past is not late, it is simply further through its cycle.
    ///
    /// `CACurrentMediaTime()` rather than a `Date`, because that is the clock `CAAnimation`
    /// measures `beginTime` on. It does not advance while the machine is asleep, which is the
    /// behaviour wanted: a window that comes back from a lid close finds every mark where it left
    /// it rather than somewhere a wall clock would have carried it.
    private(set) var epoch: CFTimeInterval = 0

    private init() {}

    /// Starts or stops the heartbeat. Idempotent, so the driver can call it on every change
    /// without checking whether anything moved.
    ///
    /// Starting it is one assignment. There is no timer to arm and nothing wakes up afterwards:
    /// the marks read `epoch` once each, build their animations from it, and the render server
    /// does the rest.
    func setTicking(_ wanted: Bool) {
        guard wanted != isTicking else { return }
        if wanted { epoch = CACurrentMediaTime() }
        isTicking = wanted
    }
}

// MARK: - Driver

/// Decides when the window's heartbeat runs, and is the only thing that does.
///
/// Two conditions, and each of them is a case that was argued somewhere else in this app already.
///
/// **Something is running.** Read from `AppModel.runningWorkspaceIDs`, which is the one observable
/// set the transcript writes when a turn starts or ends. Nothing here keeps a count of its own:
/// see that property for what happened the last time a reader did.
///
/// **Reduce Motion is off.** Dropped rather than slowed, matching `RowArrival` and the pane
/// animations. Every mark keeps its meaning without it, which is the test the mockup applied: the
/// rule holds a quiet accent tint and a row holds a whole dot at full strength. Read here rather
/// than at the marks, so a call site cannot keep half the mechanism.
///
/// # The third condition, and why it is gone
///
/// It used to stop the heartbeat while the window was not the front one, and `ActivityDot` carried
/// a second copy of that gate. The argument was a real measurement of the wrong mechanism: a
/// SwiftUI `.animation(_:value:)` is interpolated on the main thread, so a mark that never stopped
/// kept a backgrounded window off the idle path for as long as an agent ran. Nothing here is a
/// SwiftUI animation any more. A `CAAnimation` handed to a layer is copied into the render server
/// and interpolated there on the display's own clock, and this process is not woken for a frame of
/// it, so a window behind a browser costs the same whether its marks are moving or parked.
///
/// What the gate cost is the one thing these marks are for. A window put to one side while five
/// agents work is exactly the window whose marks are worth reading, and it was the window that
/// showed them frozen.
struct BusyPulseDriver: ViewModifier {
    let app: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Reading the set is what subscribes this body to it, and the write that adds or removes
        // an id is what brings the heartbeat up and takes it down again. There is no poll here and
        // no second flag: the last agent finishing is the same event everything else in the window
        // hears.
        let wanted = !app.runningWorkspaceIDs.isEmpty && !reduceMotion

        return content.onChange(of: wanted, initial: true) { _, on in
            BusyPulse.shared.setTicking(on)
        }
    }
}

extension View {
    /// Runs the window's heartbeat while agents are working. See `BusyPulseDriver`.
    func runsBusyPulse(_ app: AppModel) -> some View {
        modifier(BusyPulseDriver(app: app))
    }
}

// MARK: - Layers

/// What every mark is made of: a layer-backed view that is handed a repeating `CAAnimation` once
/// and then left alone.
///
/// This is the whole point of the rewrite, so it is worth being plain about what it buys. A
/// `CAAnimation` added to a layer is copied into the render server, which interpolates it on the
/// display's own clock. The application process is not involved in a frame of it. A SwiftUI
/// `.animation(_:value:)` is the opposite: SwiftUI owns the interpolation, so every frame is a
/// main thread wake, a view graph update and a display list render whose size is the window's, not
/// the mark's.
///
/// Two rules keep an animation on the cheap side of that line, and both are followed by every mark
/// that subclasses this:
///
/// - It repeats forever, so nothing has to restart it. `repeatCount` is infinite and
///   `isRemovedOnCompletion` is false.
/// - Its phase comes from an absolute `beginTime` rather than from the moment it was added, so two
///   layers that started at different moments are still in step. `BusyPulse.epoch` is that
///   instant, and a `beginTime` already in the past is exactly what puts a late arrival mid
///   stride.
///
/// The colours are the other half. A `CALayer` holds a `CGColor`, which is one appearance's
/// answer, where the palette's colours are `NSColor`s that answer per appearance. So every layer
/// colour is resolved against the view's own `effectiveAppearance` and resolved again when that
/// changes, which is what `viewDidChangeEffectiveAppearance` is doing here. Without it a mark keeps
/// the colour it was built in and a window switched to dark draws the light in the light
/// appearance's teal.
class BusyPulseLayerView: NSView {
    /// Layer backed from the first moment, because everything here is layer geometry and a view
    /// that gains its layer later would have to build itself twice.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Top left origin, so a sublayer's frame is written the way every other measurement in this
    /// app is written. AppKit mirrors the layer geometry to match, so `y` grows downward for the
    /// sublayers as well.
    override var isFlipped: Bool { true }

    /// Nothing here is drawn by AppKit, so nothing is redrawn when the window resizes.
    override var wantsUpdateLayer: Bool { true }

    /// Not part of any responder chain and not a hit target. The marks are a signal, not a
    /// control, and the views they sit inside already say so.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Overridden by each mark. Called on creation, on any configuration change, and whenever the
    /// appearance changes under the view.
    func applyColors() {}

    /// Resolves a palette colour against this view's appearance, which is the only place a
    /// `CGColor` may be taken from an `NSColor` that answers per appearance.
    final func resolved(_ color: NSColor) -> CGColor {
        var answer = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            answer = color.cgColor
        }
        return answer
    }

    /// Adds an animation under a key, replacing whatever was there.
    ///
    /// `beginTime` is converted into the layer's own time space rather than used raw. They are the
    /// same number for a layer nobody has given a speed or an offset to, which is every layer
    /// here, and converting is what keeps that from being a thing to remember.
    final func install(_ animation: CAAnimation, on target: CALayer, key: String, beginAt: CFTimeInterval) {
        animation.beginTime = target.convertTime(beginAt, from: nil)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        target.removeAnimation(forKey: key)
        target.add(animation, forKey: key)
    }

    /// The pulse every mark here is made of: half a period between the two ends of an envelope the
    /// core holds, played forwards and then backwards forever.
    ///
    /// **It was written twice, as `PulsingDotView.pulse` and the activity rule's own fade, line for
    /// line.** They could only ever have been the same: `BusyRule.period` IS `BusyDot.period` by
    /// construction, so the duration was one number reached down two paths. The frame rate cap is
    /// the one thing that genuinely differed, so it is a parameter and each caller keeps its own
    /// argument and the arithmetic behind it.
    ///
    /// `easeInEaseOut` and `autoreverses` rather than a keyframed envelope, because both envelopes
    /// *are* cubic eases and Core Animation's timing functions are cubic beziers. `BusyBreath` is
    /// sampled instead only because its two eased stretches are power curves, which a bezier could
    /// approximate and not express. `easeInEaseOut` is symmetric in time, so the return leg is the
    /// same curve rather than a different one run backwards, and the mark is momentarily still at
    /// each end.
    ///
    /// Half of `period`, because `autoreverses` plays the return leg: one pulse is two of these.
    final func pulse(
        _ keyPath: String,
        from: Double,
        to: Double,
        period: TimeInterval,
        frameRate: CAFrameRateRange
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = period / 2
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.autoreverses = true
        animation.preferredFrameRateRange = frameRate
        return animation
    }
}
