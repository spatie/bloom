import AppKit
import BloomCore
import SwiftUI

/// Branches leaving a line and coming back to it, with the light travelling rather than the line.
///
/// The runbloom.app hero draws a git history and nothing else: a horizontal `main` across the
/// middle, worktrees curving away from it and rejoining, a bloom of light around each. It is the
/// one picture on the site that is the app rather than a decoration of it, and it reads as water
/// at the same time, because a branch leaving a spine and returning is the shape of a swell. This
/// is that figure on the welcome window.
///
/// What came over from the site: the geometry, which is `BranchCurve` in the core; the spine
/// under the mark; the tracing, so what moves is a length of light along a curve rather than the
/// curve itself; the soft wide stroke under the sharp one, which is what makes a line look like
/// light in water rather than like a line; and the drift of light along `main` between branches.
///
/// What did not: every label, the agent names, the branch names, the commit dots and the `+3`
/// counts. The site's version is a diagram and wants reading. This is the first screen anybody
/// sees and wants only to be felt, and a screen with `feat/app-intents` written on it is a screen
/// somebody stops to parse. What is left says parallel work on one repository without naming any
/// of it.
///
/// It replaced three concentric rings going out from the mark. The rings were a sounding, which
/// tied the greeting to the checks screen's sounding line, and they were readable because they
/// were faint and slow. They were also a circle expanding out of a square mark, which is a
/// gesture any app could make; this is Bloom's own picture, and it earns the extra complexity by
/// being the thing the app does.
///
/// Core Animation, and at twenty frames a second rather than `BrandWater`'s twelve, which is the
/// one number on this view that is not the water's.
///
/// It was twelve, taken from `BrandWater.frameRate` by citation, and the reason did not come with
/// the number. That cap is argued on a gradient breathing in place: the water's fastest pool
/// changes its brightest pixel by about two levels of two hundred and fifty five a second, so at
/// twelve frames a step is a sixth of a level and nothing a gradient can show. Nothing here
/// breathes in place. Seven fifty eight point blooms travel along their curves at between twenty
/// seven and forty two points a second, and a 1.3 point stroke draws itself out behind each of
/// them at the same speed. A cap that is right for brightness changing is not therefore right
/// for a thing moving, and this is where that went wrong.
///
/// Measured the way the original was, by redrawing the composition off screen and diffing
/// consecutive frames. At twelve the water and the drifts along `main` change at most two levels
/// per step and shift no pixel by more than eight, which is the original measurement confirmed
/// rather than doubted. The branch heads change eighteen levels per step and shift more than
/// eight thousand pixels by more than eight levels in that one step, because a bloom whose alpha
/// ramps to nothing over twenty points of radius carries about two and a third levels for every
/// point it moves, and at twelve frames it moves three and a half. A maximum blend of one second
/// of that is a string of separate beads where sixty frames draws one streak. At twenty the step
/// is twelve levels and three hundred and sixty pixels, at thirty nine levels and one pixel, at
/// sixty six levels and none. Six is the floor rather than the trend: it is the head's own fade
/// near the loop point, which no frame rate touches.
///
/// Twenty rather than thirty, and the threshold is film's. A pan is held to about a screen width
/// in seven seconds at twenty four frames, which on a 520 point plinth is three points a frame
/// before an edge starts to strobe. At twelve the fastest head moves three and a half points a
/// frame, over the line; at twenty it moves two and a tenth, under it; thirty buys a further
/// seven tenths of a point that nobody asked for. See `frameRate` for what each of them costs.
///
/// One rate for the whole view rather than twenty for the heads and twelve for the drifts, which
/// looks like the thrifty version and is not. The render server recomposites the whole window
/// surface on the fastest tick anything in it asks for, so a split rate saves the interpolation
/// of two positions and none of the compositing. It is also why `BrandWater` keeping twelve is
/// not a saving on this screen: it keeps its own number for the About window, where it is the
/// only thing moving and the measurement it carries is the whole story.
///
/// And the bill is bounded by the screen it is drawn on. This figure is the greeting only. Press
/// the button and the branches are gone and the band at the top of the checks step is
/// `BrandWater` alone at twelve, so the extra frames are spent on the screen somebody is walking
/// past rather than on a window that gets left open.
struct BrandBranching: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where `main` runs, in points down from the top of the view. The call site puts it through
    /// the middle of the app mark, so the mark sits on the line the branches leave from.
    let spineDepth: CGFloat

    func makeNSView(context: Context) -> BrandBranchingView { BrandBranchingView() }

    func updateNSView(_ view: BrandBranchingView, context: Context) {
        view.spineDepth = spineDepth
        // Removed, not slowed, which is the rule every call site of `Motion` follows. Unlike the
        // rings this replaced, there is something worth holding still here: a ring at rest is a
        // circle drawn round the mark and says nothing, but branches at rest are a spine with
        // seven worktrees caught at seven different distances out along it, which is a picture of
        // the same thing the motion is a picture of. So Reduce Motion gets a composition rather
        // than an empty plinth. The site does the same in its own `seedStillFrame`.
        view.setMoving(!reduceMotion)
    }
}

final class BrandBranchingView: NSView {
    var spineDepth: CGFloat = 86 {
        didSet { if spineDepth != oldValue { needsLayout = true } }
    }

    /// The seven branches, and why there are seven of them at these seven periods.
    ///
    /// It was four, on the reasoning that three left the field empty for seconds at a time and
    /// five had two lines crossing the wordmark at once, and four was asked to be more. The five
    /// that failed failed because the fifth was put below, where the only room left is the room
    /// the type is in; going up and sideways instead costs nothing, because the plinth above the
    /// mark is empty and the picture was only ever using half the width at a time.
    ///
    /// So the three that were added are two more above the spine and one more below it but well
    /// clear of the wordmark, and every branch was shortened and moved off the middle. What
    /// stops seven reading as busy is not that they are faint, it is that no two of them share a
    /// stretch of the plinth: the runs sit at seven heights and the spans are cut into a left
    /// half, a right half and a long middle, so two heads at the same distance out are still in
    /// two different places. `-80` is still the only run that passes behind the type, and it is
    /// still the dimmest colour, which is the whole reason it is allowed to.
    ///
    /// The periods stay mutually coprime, which is what keeps the composition from ever falling
    /// into lockstep, and that is why two of them are not prime: nine and sixteen are a power of
    /// three and a power of two, so they share no factor with each other or with the five primes
    /// beside them, and they fill the gaps at the fast end that the primes leave. The lowest
    /// common multiple of the seven is over nine years.
    ///
    /// They are assigned longest branch to longest period, which is the part that makes seven
    /// lights read as one family rather than as seven separate animations: a head covers between
    /// twenty seven and forty two points a second whichever branch it is on, where the four
    /// used to run from fourteen to twenty seven. That is the quicker Freek asked for, a little
    /// under twice the pace of the old average, and it is spent on the whole set rather than on
    /// the front of it.
    ///
    /// `rise` is signed points off the spine, positive upwards, and the spread is deliberately
    /// not symmetric: there is only the plinth above the mark, and the wordmark below it. Colour
    /// darkens with depth for the same reason, so the lines nearest the type are the ones least
    /// able to compete with it.
    private struct Lane {
        var from: CGFloat
        var to: CGFloat
        var rise: CGFloat
        var period: CFTimeInterval
        var colour: UInt32
        /// Where this branch is caught when nothing is moving, as a fraction of its own travel.
        var still: CGFloat
    }

    /// Ordered top to bottom, so the reason the colours darken down the list is visible in it.
    /// The stills are seven roughly even steps through a cycle, dealt out so that neighbours in
    /// height are never neighbours in progress; see `stillFrame` for what that is holding.
    private static let lanes: [Lane] = [
        Lane(from: 0.04, to: 0.60, rise: 132, period: 23, colour: 0x9BE9DC, still: 0.70),
        Lane(from: 0.52, to: 1.00, rise: 112, period: 16, colour: 0x9BE9DC, still: 0.58),
        Lane(from: 0.00, to: 0.46, rise: 98, period: 13, colour: 0x7FE8D6, still: 0.36),
        Lane(from: 0.16, to: 0.78, rise: 62, period: 17, colour: 0x7FE8D6, still: 0.12),
        Lane(from: 0.54, to: 1.00, rise: -46, period: 11, colour: 0x4FD8C4, still: 0.47),
        Lane(from: 0.00, to: 0.42, rise: -50, period: 9, colour: 0x4FD8C4, still: 0.24),
        Lane(from: 0.28, to: 0.92, rise: -80, period: 19, colour: 0x2AA3B4, still: 0.86),
    ]

    /// The share of a branch's period spent tracing out to the far end. The rest of it is the
    /// tail catching up, which is how the light lands back on the spine and is gone.
    private static let trace: CFTimeInterval = 0.72
    /// How far behind the head each of the two strokes trails, as a share of the period.
    ///
    /// Two numbers rather than one, and this is what makes a branch read as light rather than as
    /// a dash sliding along a curve. The sharp line keeps a bit over a fifth of the branch lit,
    /// which is enough to show the shape of the turn it just came round and not so much that it
    /// draws the whole branch. The soft wide one behind it keeps half again as much, so what
    /// fades out at the back is a glow with no line left inside it. The site gets the same effect
    /// with a gradient stroke on its trail; this gets it from two layers and no gradient, which
    /// is what the render server can animate without being handed a new path every frame.
    ///
    /// Both were cut back when the count went from four to seven and the pace went up, and the
    /// two changes wanted the same cut for different reasons. Seven branches lit for a third of
    /// their length is a third more lit line on the plinth than four were, which is the busy this
    /// had to stay away from; and a light moving half again as fast wants a shorter trail anyway,
    /// because a long one at speed stops reading as a bloom being carried and starts reading as a
    /// stripe being dragged.
    private static let lineLag: CFTimeInterval = 0.16
    private static let wakeLag: CFTimeInterval = 0.27
    /// Twenty, not `BrandWater.frameRate`'s twelve, and the type's own note is why.
    ///
    /// What the extra frames cost, sampled rather than reasoned about, because the last time
    /// somebody reasoned about it this file inherited the wrong number. A harness holding this
    /// plinth and nothing else, in a 520 by 424 window in a corner of the display, showing and
    /// hiding itself on twenty second phases with WindowServer sampled every ten: shut, it sat at
    /// 4.8 percent of one core; at twelve frames it cost 3.5 points over the shut phases either
    /// side of it, at twenty 6.5, at thirty 10.8. So this change is worth about three points of
    /// one core, and thirty would have been seven. Both are paid only while the greeting is on
    /// screen. The phases alternate because WindowServer's own load on this machine wanders
    /// between two and forty five percent with whatever else is drawing, so an absolute number is
    /// worth nothing and only a sample next to its own baseline says anything.
    ///
    /// The window that this was originally measured on is still the one to worry about and it is
    /// untouched: the About window has no branches, only `BrandWater` at twelve.
    ///
    /// Fifteen and twenty rather than a range around twenty because both ends have to divide the
    /// refresh of the display this lands on. Fifteen and twenty go into sixty and into a hundred
    /// and twenty; twenty four goes into a hundred and twenty and not into sixty, so on an
    /// ordinary display it would be handed back as an uneven cadence, which is the judder these
    /// frames are being spent to remove.
    private static let frameRate = CAFrameRateRange(minimum: 15, maximum: 20, preferred: 20)
    /// How many points the head's travel is sampled into. Forty is under three points apart on
    /// the longest branch here, which is inside the softest edge in the composition.
    private static let steps = 40

    private let spine = BrandBranchingView.spineLayer()
    private let drifts = [BrandBranchingView.glow(rgb: 0x2AA3B4, alpha: 0.20),
                          BrandBranchingView.glow(rgb: 0x4FD8C4, alpha: 0.14)]
    private var wakes: [CAShapeLayer] = []
    private var lines: [CAShapeLayer] = []
    private var heads: [CAGradientLayer] = []
    /// The paced points of each branch, kept from layout so the head's keyframes and the still
    /// frame's parking spot are read off the same line the stroke is drawn from.
    private var tracks: [[CGPoint]] = []
    private var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(spine)
        for drift in drifts { layer?.addSublayer(drift) }
        for lane in Self.lanes {
            // The wide soft stroke first and the sharp one over it, which is the order the site
            // paints in and the only order that reads as light around a line rather than as two
            // lines. Both are one layer each with one path: the whole travel is `strokeStart` and
            // `strokeEnd`, so the render server owns it and nothing is re-pathed per frame.
            let wake = CAShapeLayer()
            wake.fillColor = NSColor.clear.cgColor
            wake.strokeColor = NSColor(rgb: lane.colour).withAlphaComponent(0.11).cgColor
            wake.lineWidth = 7
            wake.lineCap = .round
            wake.opacity = 0
            let line = CAShapeLayer()
            line.fillColor = NSColor.clear.cgColor
            line.strokeColor = NSColor(rgb: lane.colour).withAlphaComponent(0.55).cgColor
            line.lineWidth = 1.3
            line.lineCap = .round
            line.opacity = 0
            let head = Self.glow(rgb: lane.colour, alpha: 0.34)
            head.opacity = 0
            layer?.addSublayer(wake)
            layer?.addSublayer(line)
            layer?.addSublayer(head)
            wakes.append(wake)
            lines.append(line)
            heads.append(head)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `main`, faded out at both ends rather than run to the window edges.
    ///
    /// A hairline reaching both walls of the plinth is a border, and a border across the top of
    /// the first screen the app draws is the one thing this cannot look like. Faded, it reads as
    /// a current the branches come off, and the middle of it is hidden behind the mark anyway.
    private static func spineLayer() -> CAGradientLayer {
        let spine = CAGradientLayer()
        let colour = NSColor(rgb: 0x2AA3B4)
        spine.colors = [
            colour.withAlphaComponent(0).cgColor,
            colour.withAlphaComponent(0.26).cgColor,
            colour.withAlphaComponent(0.26).cgColor,
            colour.withAlphaComponent(0).cgColor,
        ]
        spine.locations = [0, 0.16, 0.84, 1]
        spine.startPoint = CGPoint(x: 0, y: 0.5)
        spine.endPoint = CGPoint(x: 1, y: 0.5)
        return spine
    }

    /// A soft round light: `BrandWater`'s pool, at the size a head of a branch wants. Radial to
    /// nothing by seventy percent of the radius, which is the site's `transparent 70%` and what
    /// keeps it a bloom rather than a disc.
    private static func glow(rgb: UInt32, alpha: CGFloat) -> CAGradientLayer {
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [
            NSColor(rgb: rgb).withAlphaComponent(alpha).cgColor,
            NSColor(rgb: rgb).withAlphaComponent(0).cgColor,
            NSColor(rgb: rgb).withAlphaComponent(0).cgColor,
        ]
        glow.locations = [0, 0.7, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        return glow
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // The core works in the same space the view draws in, so the only conversion is the one
        // between "down from the top", which is how the greeting is laid out, and the layer
        // geometry it lands in.
        let spineY = bounds.height - spineDepth
        spine.frame = CGRect(x: 0, y: spineY - 0.5, width: bounds.width, height: 1)
        for drift in drifts {
            drift.bounds = CGRect(x: 0, y: 0, width: 260, height: 90)
            drift.position = CGPoint(x: bounds.midX, y: spineY)
        }

        tracks = Self.lanes.enumerated().map { index, lane in
            let shape = BranchCurve.shape(
                from: lane.from * bounds.width,
                to: lane.to * bounds.width,
                spine: spineY,
                rise: lane.rise,
                crown: 7
            )
            let track = BranchCurve.paced(shape, count: Self.steps)
            let path = CGMutablePath()
            path.addLines(between: track)
            for stroke in [wakes[index], lines[index]] {
                // Each stroke is given the branch's own box rather than the whole view, so the
                // render server recomposites a band around one curve instead of the whole plinth
                // four times over.
                let box = path.boundingBox.insetBy(dx: -8, dy: -8)
                stroke.frame = box
                var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
                stroke.path = path.copy(using: &shift)
            }
            heads[index].bounds = CGRect(x: 0, y: 0, width: 58, height: 58)
            heads[index].position = track.first ?? .zero
            return track
        }

        CATransaction.commit()
        applyMotion()
    }

    func setMoving(_ wanted: Bool) {
        moving = wanted
        applyMotion()
    }

    private func applyMotion() {
        for layer in drifts + wakes + lines + heads { layer.removeAllAnimations() }
        guard bounds.width > 0, !tracks.isEmpty else { return }
        guard moving else { return stillFrame() }

        for (index, lane) in Self.lanes.enumerated() {
            // Wound forward by a share of its own period rather than delayed, so the window opens
            // onto branches already out on the water instead of onto an empty spine.
            let phase = lane.period * CFTimeInterval(lane.still)
            trace(wakes[index], lag: Self.wakeLag, over: lane.period, phase: phase)
            trace(lines[index], lag: Self.lineLag, over: lane.period, phase: phase)
            travel(heads[index], along: tracks[index], over: lane.period, phase: phase)
        }
        drift(drifts[0], over: 27, phase: 0)
        drift(drifts[1], over: 38, phase: 19)
    }

    /// What the window shows when Reduce Motion is on: the spine, and seven branches held at
    /// seven different distances out from it, each lit for the length it would be lit while
    /// moving. One is landing, one has just left, the other five are spread along their runs. It
    /// is the same picture, stopped.
    ///
    /// Holding seven still takes more care than holding four did, because a still frame cannot
    /// rely on time to separate anything: whatever the stills say is what is seen for as long as
    /// the window is open. So they are dealt out against the heights rather than down them, and
    /// the two that read as events, the one landing and the one just departed, are put at
    /// opposite ends of the plinth and on opposite sides of the spine.
    private func stillFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, lane) in Self.lanes.enumerated() {
            let head = min(lane.still / CGFloat(Self.trace), 1)
            for (stroke, lag) in [(wakes[index], Self.wakeLag), (lines[index], Self.lineLag)] {
                stroke.strokeStart = max((lane.still - CGFloat(lag)) / CGFloat(Self.trace), 0)
                stroke.strokeEnd = head
                stroke.opacity = 1
            }
            let track = tracks[index]
            let step = min(Int(head * CGFloat(track.count - 1)), track.count - 1)
            heads[index].position = track[step]
            heads[index].opacity = 0.85
        }
        // Parked a quarter and three quarters of the way along rather than where they were laid
        // out, because the middle of the spine is behind the mark and a light held still there is
        // a light nobody can see.
        for (index, drift) in drifts.enumerated() {
            drift.position.x = bounds.width * (index == 0 ? 0.26 : 0.74)
            drift.opacity = 0.55
        }
        CATransaction.commit()
    }

    /// The branch drawing itself out and then being drawn back in.
    ///
    /// `strokeEnd` runs the whole length over the first `trace` of the period and `strokeStart`
    /// follows it a `lag` behind, so the lit part is a length of the curve travelling along it
    /// rather than a line growing. When the head reaches the spine the tail keeps going, and the
    /// light shrinks into the rejoin and is gone, which is the only part of the site's version
    /// that is about merging and the only part worth keeping without a label to explain it.
    private func trace(
        _ stroke: CAShapeLayer,
        lag: CFTimeInterval,
        over period: CFTimeInterval,
        phase: CFTimeInterval
    ) {
        let head = CAKeyframeAnimation(keyPath: "strokeEnd")
        head.values = [0, 1, 1]
        head.keyTimes = [0, NSNumber(value: Self.trace), 1]
        let tail = CAKeyframeAnimation(keyPath: "strokeStart")
        tail.values = [0, 0, 1]
        tail.keyTimes = [0, NSNumber(value: lag), 1]
        // Rises out of nothing and is gone before the loop point, so neither end of the cycle is
        // ever seen happening.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.09, 0.90, 1]
        stroke.add(group([head, tail, fade], over: period, phase: phase), forKey: "trace")
    }

    /// The bloom that rides on the head of a branch.
    ///
    /// Its positions are the branch's own points, paced by `BranchCurve` so the light holds one
    /// speed through the turns as well as along the run. A keyframe interpolates on even key
    /// times, so unpaced points would have it race the corners, and the corners are exactly where
    /// the eye is because that is where the branch leaves.
    private func travel(
        _ glow: CAGradientLayer,
        along track: [CGPoint],
        over period: CFTimeInterval,
        phase: CFTimeInterval
    ) {
        guard track.count > 1 else { return }
        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = (track + [track[track.count - 1]]).map { NSValue(point: $0) }
        path.keyTimes = (0..<track.count).map {
            NSNumber(value: Double($0) / Double(track.count - 1) * Self.trace)
        } + [NSNumber(value: 1.0)]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0.9, 0]
        fade.keyTimes = [0, 0.06, 0.66, 1]
        glow.add(group([path, fade], over: period, phase: phase), forKey: "travel")
    }

    /// Light going down `main` itself, so the spine is not the one still thing in the picture
    /// between branches. The site drifts three of these along its spine; two is enough here,
    /// because half the line is behind the mark.
    private func drift(_ glow: CAGradientLayer, over seconds: CFTimeInterval, phase: CFTimeInterval) {
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = -140
        travel.toValue = bounds.width + 140
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.18, 0.82, 1]
        glow.add(group([travel, fade], over: seconds, phase: phase), forKey: "drift")
    }

    private func group(
        _ animations: [CAAnimation],
        over seconds: CFTimeInterval,
        phase: CFTimeInterval
    ) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = seconds
        group.repeatCount = .infinity
        group.preferredFrameRateRange = Self.frameRate
        group.timeOffset = phase
        return group
    }
}
