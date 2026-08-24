import SwiftUI
import QuartzCore
import BloomCore

/// How far the window's shared rule runs, so one light can travel the whole of it.
///
/// The rule under the title bar is drawn by two views that know nothing about each other: the
/// centre column's tab strip draws it behind its tabs (see `tabStripMaterial`), and the inspector
/// draws it inside its own tab row (see `InspectorView`). `f5c591f` is what put both on the same
/// line. A light that travelled only one of them would die at the split divider on a line that
/// visibly carries on, so the two segments have to agree where the line starts and how long it is.
///
/// Only the strip's width is published here. The inspector's is already the one number
/// `InspectorGeometry` exists to carry, measured by the split controller on every layout pass,
/// and a second copy of it could only ever disagree with the first.
///
/// The sidebar is not part of this. It has no rule at y=83 at all, measured on a two times capture:
/// at the row the rule occupies the sidebar is flat chrome from the window's edge to the vertical
/// hairline that closes the column off. So the rule starts at the centre column's leading edge,
/// which is where the light enters.
@MainActor
@Observable
final class SharedRule {
    static let shared = SharedRule()

    /// The centre column's tab strip: the segment the rule starts on. Zero on Home and on an
    /// archived workspace, neither of which has a strip.
    private(set) var stripWidth: CGFloat = 0

    private init() {}

    func setStripWidth(_ value: CGFloat) {
        guard abs(stripWidth - value) > 0.5 else { return }
        stripWidth = value
    }

    /// Where the inspector's segment begins, measured along the rule from its own start.
    ///
    /// The split view's divider is `.thin`, which is one point: measured at two times, the centre
    /// column's rule stops at the divider and the inspector's resumes two pixels later. The light
    /// is dark for that one point, exactly as the rule is.
    var inspectorOrigin: CGFloat {
        stripWidth > 0 ? stripWidth + Metrics.hairline : 0
    }

    /// How long the whole rule is.
    var length: CGFloat {
        let inspector = InspectorGeometry.shared
        guard inspector.isVisible else { return stripWidth }
        return inspectorOrigin + inspector.width
    }
}

/// The light that travels the window's shared rule while an agent is working.
///
/// # Which rule, and why this one
///
/// The owner picked the rule at y=83, the one that closes off the tab strip, and the study that
/// drew the five variations argued against it: the selected tab's fill breaks that rule, so a
/// light crossing it disappears for the width of the tab and steps out the other side. Three ways
/// out were on the table and two of them do not survive a measurement.
///
/// **The rule at y=52 does not exist.** The study called it "the only line in the window that
/// crosses all three columns" and it is not a line at all. Sampled on a two times capture at
/// 1200 by 760: at y=52 the sidebar is flat chrome, the centre column is the tab strip's recess
/// tint, and only the inspector carries a hairline, because only the inspector has a white pane
/// beginning there. Sweeping y=52 would mean drawing a new full width line across the window to
/// have something to sweep, which is not moving the light onto an existing rule, it is adding a
/// rule. That option is off the table on the evidence rather than on taste.
///
/// **Sweeping only the continuous part** would mean the inspector's segment alone, which is 380
/// points of a 1400 point window, is gone the moment the inspector is closed, and speaks from the
/// far edge of the window about work happening in the middle of it.
///
/// **So the light passes behind the tab**, and the reason that reads as occlusion rather than as a
/// stutter is that it is occlusion. The light is drawn where the rule is drawn: inside
/// `tabStripMaterial`'s background, over the hairline and under the tabs. The selected tab's own
/// opaque fill is what breaks the rule, and it breaks the light on exactly the same pixels, at
/// exactly the same edges. Nothing steps: the light goes out at the tab's leading edge and comes
/// back at its trailing one, having crossed behind it at the speed it was already travelling.
/// A light that stutters is one drawn over the tab and clipped by something else; this one is
/// under it. Verified at 1x and 2x, in both appearances, with a tab selected and with none.
///
/// # Out, and back
///
/// The light crosses the rule, turns round on the far end and crosses back, rather than crossing
/// once and jumping to the leading edge to start again. That is the shape of the one indeterminate
/// bar every Mac already has, and it was read off that bar rather than guessed at: an indeterminate
/// `NSProgressIndicator` carries a repeating group on the layer that holds its pill, and inside it
/// a keyframed `transform` whose two values are the identity and a horizontal mirror of the track,
/// held for half the cycle each. One pass of the pill, played twice, seen the second time in a
/// mirror. Sampled off the presentation layer at fifty milliseconds, the pill's travel inside a
/// pass runs 8, 16, 22, 31, 38, 43, 47, 45, 44, 39, 32, 25, 17, 10, 3 points: an ease in and out
/// whose peak is 1.68 times its mean, where a cubic ease in and out is 1.66. So both ends of every
/// pass are eased, and the mirror is what turns it round.
///
/// This does the same thing without the mirror, because a mirror would also reverse the gradient
/// and the light is symmetric anyway. `autoreverses` on one eased crossing is what turns it round,
/// and because `easeInEaseOut` is symmetric in time its reverse is itself: the return leg is the
/// same curve, not a curve run backwards into a different shape. The light therefore arrives at an
/// end with its speed at zero and leaves it with its speed at zero, which is the whole of why the
/// turn does not read as a bounce off a wall.
///
/// The turn happens *on* the rule. The old pass ran the light off both ends, because the return
/// was a jump and a jump has to happen where it cannot be seen; there is no jump left to hide, so
/// the light travels between the two ends of the rule itself and the turn is something to look at
/// rather than something that happened offstage.
///
/// # What it costs
///
/// One `CABasicAnimation` on `position.x` of one 160 by 1 gradient layer per segment, added when
/// the light appears and never touched again. Core Animation interpolates it in the render server,
/// so the app is not woken for a frame of it, and this body runs when the rule's length changes
/// and at no other time.
///
/// It used to be a SwiftUI `.offset` animated by `.animation(_:value:)`, restarted twice a cycle
/// off a shared tick, and that is a different thing entirely: SwiftUI interpolates such an
/// animation itself, on the main thread, re-rendering the display list of the whole hosting view
/// once per display frame. Measured on a 120Hz panel with five agents running, four interleaved
/// passes against this version back to back: the two marks between them cost a median of 2.96
/// seconds of CPU every 15, where the pair now costs 0.13 against a floor of 0.20 with the
/// heartbeat off entirely. See `BusyPulse` for what Instruments said about where the 2.96 went.
struct RuleSweep: View {
    /// Which piece of the rule this is. It decides where along the rule the light enters, and
    /// nothing else: both segments run the same animation over the same distance at the same
    /// moment, which is what makes the crossing continuous, in either direction.
    enum Segment {
        case tabStrip
        case inspector
    }

    var segment: Segment

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pulse: BusyPulse { .shared }
    private var rule: SharedRule { .shared }

    /// How long the light is. Wide enough to read as a soft pass rather than as a dot, short
    /// enough that most of the rule is untouched at any moment.
    static let length: CGFloat = 160

    /// What the rule holds while an agent is working and nothing is moving, which is Reduce Motion
    /// and nothing else now. A tint rather than nothing at all, because the signal has to
    /// survive being frozen, and quiet enough that a screenshot does not read as a rule drawn in
    /// the wrong colour.
    private static let restingOpacity: Double = 0.32

    /// Read from the one observable set, not from a flag of this view's own. See
    /// `AppModel.runningWorkspaceIDs`.
    private var isRunning: Bool { !app.runningWorkspaceIDs.isEmpty }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .clipped()
            // The signal goes out rather than being cut off. An agent's turn can finish at any moment,
            // including with the light halfway along the rule, and a full strength segment
            // vanishing between two frames in the middle of the window is a pop. Measured on a
            // capture of three agents finishing one after another: the pass in flight when the
            // last one ended was two thirds of the way across. A fifth of a second is short
            // enough that nothing is being claimed after it stopped being true, which is the
            // whole point of `runningWorkspaceIDs`.
            .opacity(isRunning ? 1 : 0)
            .animation(reduceMotion ? nil : Motion.pane, value: isRunning)
            .allowsHitTesting(false)
            // The strip measures itself here rather than in `TabStrip`, so the one view that needs
            // the number is the one that asks for it. Rounded to whole points, so a divider drag
            // does not write observable state once a frame.
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width in
                guard segment == .tabStrip else { return }
                rule.setStripWidth(width)
            }
    }

    @ViewBuilder
    private var content: some View {
        if pulse.isTicking {
            // A layer rather than a view, and the resting state below is deliberately not one.
            // Only the moving state has anything to gain from Core Animation, and keeping the
            // still one in SwiftUI is what lets `ImageRenderer` still draw a rule that is not
            // sweeping. See `Snapshot`, which cannot draw an `NSViewRepresentable` at all.
            SweepLight(travel: rule.length, origin: origin, epoch: pulse.epoch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Rectangle()
                .fill(Palette.accent)
                .opacity(Self.restingOpacity)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.hairline)
        }
    }

    /// Where this segment starts, measured along the whole rule. The light's travel is written in
    /// the rule's coordinates and each segment subtracts its own start, which is what makes a
    /// crossing continuous over the divider: the two layers are always at the same place on the
    /// same line, one of them simply outside its own bounds and clipped away.
    private var origin: CGFloat {
        segment == .tabStrip ? 0 : rule.inspectorOrigin
    }
}

// MARK: - The light

/// The moving half of `RuleSweep`: a gradient layer that crosses the rule and comes back.
private struct SweepLight: NSViewRepresentable {
    /// How far the light travels, which is the length of the whole rule rather than of this
    /// segment.
    var travel: CGFloat

    /// Where this segment begins along that rule.
    var origin: CGFloat

    /// The heartbeat's start, which is the only thing that decides where in its crossing the light
    /// is. See `BusyPulse.epoch`.
    var epoch: CFTimeInterval

    func makeNSView(context: Context) -> SweepLightView {
        let view = SweepLightView(frame: .zero)
        view.configure(travel: travel, origin: origin, epoch: epoch)
        return view
    }

    func updateNSView(_ view: SweepLightView, context: Context) {
        view.configure(travel: travel, origin: origin, epoch: epoch)
    }

    /// Fills whatever it is given. The strip and the inspector's tab row are different widths and
    /// the light is placed inside by hand, so there is nothing here for SwiftUI to measure.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SweepLightView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// A 160 by 1 gradient on a layer, crossing the rule under a repeating animation.
final class SweepLightView: BusyPulseLayerView {
    private let light = CAGradientLayer()

    private var travel: CGFloat = 0
    private var origin: CGFloat = 0
    private var epoch: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Horizontal, and symmetric about the middle. What actually travels is the bright core:
        // the two ends are clear, so at an end of the rule the far half of the gradient hangs past
        // it and the core sits on its last point. The light touches the end rather than leaving by
        // it, and it is at its dimmest exactly where it is slowest.
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        light.locations = [0, 0.5, 1]
        light.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        light.bounds = CGRect(x: 0, y: 0, width: RuleSweep.length, height: Metrics.hairline)
        layer?.addSublayer(light)
        applyColors()
    }

    override func applyColors() {
        let accent = resolved(NSColor(Palette.accent))
        let clear = accent.copy(alpha: 0) ?? accent
        light.colors = [clear, accent, clear]
    }

    /// Places the light and, if anything about its travel changed, hands Core Animation a new
    /// crossing.
    ///
    /// Guarded, because `updateNSView` runs on every pass SwiftUI makes over this view and a
    /// window being resized makes a great many of them. Reinstalling an animation that is already
    /// correct would be the per frame cost this whole change exists to remove, only in a different
    /// place.
    func configure(travel: CGFloat, origin: CGFloat, epoch: CFTimeInterval) {
        guard travel != self.travel || origin != self.origin || epoch != self.epoch else { return }
        self.travel = travel
        self.origin = origin
        self.epoch = epoch
        install()
    }

    /// The layer sits on the rule, which is the last point of this view rather than the first: the
    /// strip's own hairline is drawn at the bottom of the same box.
    override func layout() {
        super.layout()
        // Position is set by the animation, so only `y` is answered here. Written straight onto
        // the layer's model position with actions off, or AppKit's implicit animation would
        // interpolate a resize into a slide.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.position = CGPoint(x: light.position.x, y: bounds.height - Metrics.hairline / 2)
        CATransaction.commit()
    }

    private func install() {
        let start = -origin
        let end = travel - origin

        // Left where a crossing begins, so removing the animation leaves the light on the rule's
        // near end rather than wherever the last frame put it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.position = CGPoint(x: start, y: bounds.height - Metrics.hairline / 2)
        CATransaction.commit()

        // One crossing, played forwards and then backwards forever. `easeInEaseOut` is symmetric,
        // so the return leg is the same curve rather than its mirror, and the light's speed is
        // zero on the frame it reaches either end. Three seconds out and three back is the six
        // second cycle `BusyPulse` locks the sidebar's figure to.
        let crossing = CABasicAnimation(keyPath: "position.x")
        crossing.fromValue = start
        crossing.toValue = end
        crossing.duration = BusyPulse.pass
        crossing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        crossing.autoreverses = true
        install(crossing, on: light, key: "sweep", beginAt: epoch)
    }
}
