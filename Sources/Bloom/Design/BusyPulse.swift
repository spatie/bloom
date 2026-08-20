import SwiftUI
import BloomCore

/// The window's one heartbeat, while an agent is working.
///
/// Two things move while agents are running: the light that travels the shared rule under the
/// title bar (`RuleSweep`) and the figure at the head of every working row in the sidebar
/// (`WorkspaceRunningGlyph`). They read their phase from here rather than each starting a
/// `repeatForever` animation of their own, and that is the whole reason this type exists.
///
/// A `repeatForever` animation begins when the view that carries it is committed. Five agents
/// started at five different moments therefore give five row figures at five different phases,
/// which is not a rhythm, it is five things blinking at a column of names. Worse, they never
/// converge: nothing in Core Animation pulls two free running loops back together. One counter
/// that every mark reads means an agent started ten seconds after the last one is in step with it
/// on its first frame, and it means the rule and the rows are in step with each other as well, so
/// the window has one heartbeat rather than two that drift past each other.
///
/// What is shared is only the moment each animation begins. Neither mark is stepped: the light is
/// one interpolated travel and each dot in the figure is one interpolated ramp, so both are drawn
/// at whatever the display refreshes at rather than at this tick's rate. A clock that stepped the
/// pictures themselves would give the figure exactly as many frames as it had pictures, which is
/// the mistake `WorkspaceRunningGlyph` records.
///
/// The tick is the unit both marks are built from, so both are exact multiples of it: the figure
/// runs one half of its wave per tick, the light takes `passTicks` to cross the rule and
/// `sweepTicks` to go out and come back. They meet at the top of every sweep rather than every
/// forty seconds.
///
/// It runs only while something is running, and only while the window is the front one. See
/// `BusyPulseDriver`, which is the single place that decides.
@MainActor
@Observable
final class BusyPulse {
    static let shared = BusyPulse()

    /// The unit. Everything else here is a count of these.
    ///
    /// It is the half period of the sidebar's figure: the light runs down the three dots on one
    /// tick and back up them on the next, so a whole wave is a second and a half.
    static let tickInterval: Duration = .milliseconds(750)

    /// How many ticks the light takes to cross the rule once, in either direction.
    ///
    /// Four, which is three seconds, and it is the same three seconds a crossing has always
    /// taken. What changed is the end of it. The light used to spend the two ticks after a
    /// crossing parked off the far edge and then jump back to the leading one; now it turns round
    /// and crosses back. So the speed of a crossing is untouched, the dead beat is gone, and a
    /// crossing begins every three seconds where one used to begin every four and a half.
    static let passTicks = 4

    /// How many ticks the whole figure takes: out, and back.
    ///
    /// Six seconds, which is four of the sidebar figure's waves, so the two marks still meet at
    /// the top of every cycle. `4815630` locked them to each other and this keeps them locked:
    /// the count changed, the fact that it is a whole number of waves did not.
    static let sweepTicks = passTicks * 2

    /// Where the clock is in its cycle, `0 ..< sweepTicks`.
    ///
    /// Wrapped rather than counted up, so a window left open for a week is on the same numbers as
    /// one just launched and nothing has to think about an overflow.
    private(set) var tick = sweepTicks - 1

    /// Whether the clock is running at all.
    ///
    /// False is not the same as idle. An agent can be working with this false, because the window
    /// is behind somebody's browser or because Reduce Motion is on, and both marks have a resting
    /// state for exactly that: the rule holds a quiet tint and the row holds the whole figure. So
    /// what this answers is "is anything moving", and the marks ask `AppModel` itself whether
    /// anything is running.
    private(set) var isTicking = false

    /// Which way the light is travelling: towards the far end of the rule, or back to the near
    /// one.
    ///
    /// A direction rather than a position, because the two ends are all Core Animation needs. It
    /// is handed the end the light is going to and interpolates the whole crossing itself, and
    /// flipping this is the whole of what turns the light round. The same curve runs on both
    /// legs, so the light reaches an end with its speed already at zero and leaves it the same
    /// way: the turn is two halves of one movement rather than two passes stitched together.
    ///
    /// Published rather than derived from `tick` at the call site so that `RuleSweep`'s body runs
    /// twice in a cycle instead of eight times. The rows have no equivalent because their figure
    /// changes on every tick anyway.
    private(set) var isSweepingOut = false

    /// Which half of its wave the sidebar's figure is in.
    ///
    /// A boolean rather than a position, because the dots interpolate between its two values
    /// rather than being placed by it. See `WorkspaceRunningGlyph`.
    private(set) var isWaveHigh = false

    @ObservationIgnored private var clock: Task<Void, Never>?

    private init() {}

    /// Starts or stops the clock. Idempotent, so the driver can call it on every change without
    /// checking whether anything moved.
    func setTicking(_ wanted: Bool) {
        guard wanted != isTicking else { return }
        isTicking = wanted
        clock?.cancel()
        clock = nil

        guard wanted else {
            // Left where the resting states expect to find it: the light back at the near end,
            // and the figure at full strength rather than caught halfway down its own ramp.
            isSweepingOut = false
            isWaveHigh = false
            tick = Self.sweepTicks - 1
            return
        }

        // One short of the top, so the first tick is the one that starts a crossing. Without it
        // the clock would begin already inside a travel, and an animation whose value did not
        // change is an animation that never runs: the first crossing would be skipped and the
        // light would sit at the near end of the rule for six seconds.
        set(tick: Self.sweepTicks - 1)

        clock = Task { [weak self] in
            var next = ContinuousClock.now
            while !Task.isCancelled {
                next = next.advanced(by: Self.tickInterval)
                try? await Task.sleep(until: next, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.set(tick: (self.tick + 1) % Self.sweepTicks)
            }
        }
    }

    /// Deadline driven rather than sleeping for the interval each time round, so a tick that is
    /// served late does not push the next one out with it. The two marks stay in step with each
    /// other whatever happens, because they read one counter, and this is what keeps that counter
    /// in step with the clock on the wall.
    private func set(tick newTick: Int) {
        tick = newTick
        let out = newTick < Self.passTicks
        if out != isSweepingOut { isSweepingOut = out }
        let high = newTick.isMultiple(of: 2)
        if high != isWaveHigh { isWaveHigh = high }
    }
}

// MARK: - Driver

/// Decides when the window's heartbeat runs, and is the only thing that does.
///
/// Three conditions, and each of them is a case that was argued somewhere else in this app
/// already.
///
/// **Something is running.** Read from `AppModel.runningWorkspaceIDs`, which is the one observable
/// set the transcript writes when a turn starts or ends. Nothing here keeps a count of its own:
/// see that property for what happened the last time a reader did.
///
/// **Reduce Motion is off.** Dropped rather than slowed, matching `ActivityDot`, `RunningRing`,
/// `RowArrival` and the pane animations. Both marks keep their meaning without it, which is the
/// test the mockup applied: the rule holds a quiet accent tint and the row holds all three dots at
/// full strength. Read here rather than at the marks, so a call site cannot keep half the
/// mechanism.
///
/// **The window is the front one.** The same rule `RunningRing` follows, for the same reason and
/// a stronger one. An animation that never stops is what keeps a window off the idle path, and on
/// a ProMotion display it holds the display link awake for as long as an agent runs, which can be
/// hours. Behind a browser there is nothing to read anyway, and the resting states mean nothing is
/// lost when there is: the marks stop moving and stay legible, the way a background window's
/// chrome stops being tinted.
struct BusyPulseDriver: ViewModifier {
    let app: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        // Reading the set is what subscribes this body to it, and the write that adds or removes
        // an id is what brings the clock up and takes it down again. There is no poll here and no
        // second flag: the last agent finishing is the same event everything else in the window
        // hears.
        let isRunning = !app.runningWorkspaceIDs.isEmpty
        // `Snapshot.forcesBusyPulse` is false in every build anyone ships. See that property for
        // why a capture run has to be allowed past the frontmost gate.
        let isFront = activeState != .inactive || Snapshot.forcesBusyPulse
        let wanted = isRunning && !reduceMotion && isFront

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
