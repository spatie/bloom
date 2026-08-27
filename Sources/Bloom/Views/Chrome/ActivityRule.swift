import SwiftUI
import QuartzCore
import BloomCore

/// The window's shared rule while an agent is working: a lit line with a crest running along it,
/// towards the edge the next word lands at.
///
/// # What this replaced, and why, twice
///
/// **First a light travelled the rule** and was killed by contrast. It was a one point hairline in
/// the accent on a rule that is already the accent at a third strength, so the mark and the line
/// under it were the same hue and on pale chrome there was nothing to see.
///
/// **Then the whole width brightened at once**, which fixed the contrast and lost everything else.
/// The report on it was "the busy indicator, that breath of green line, is not clear at all", and
/// the three causes are written out on `BusyCrest`: one point tall in both states, so the
/// difference was alpha and alpha alone; no direction, so it could say something is happening but
/// never that text is coming; and a bottom of the cycle at 0.32, so a glance that landed on the
/// wrong half of the beat found a rule. That figure is still here, as `BusyRuleVariant.swell`, and
/// `ActivityRuleGallery` draws it beside the two that answer it, because this rule has now been
/// argued about twice and both times the argument was settled by a picture.
///
/// # Which rule, and why this one
///
/// The rule at y=83, the one that closes off the tab strip, and **the rule at y=52 does not
/// exist.** The study that drew the first set of variations called it "the only line in the window
/// that crosses all three columns"; sampled on a two times capture at 1200 by 760, at y=52 the
/// sidebar is flat chrome, the centre column is the tab strip's recess tint, and only the inspector
/// carries a hairline. Putting the signal there is not using an existing rule, it is adding one.
/// The sidebar is out for the same reason, measured the same way.
///
/// # Which segment of it, and why only one
///
/// The centre column's, and **the inspector's half is deliberately dark.** It was lit for a
/// fortnight, off this same epoch, and the report was "there seems to be two going, one in middle
/// pane, one in right". Neither half was wrong. They shared a period and therefore not a speed, so
/// two crests set off from two leading edges at two rates, and two objects is what the eye counted.
///
/// The offered alternative was one crest crossing both as though they were one track with a gap in
/// it, and it is not built. It is buildable, and the two things that would make it honest were
/// checked rather than assumed, so the next person to want it starts from the arithmetic instead of
/// from the idea.
///
/// **A segment can know where it is in the window, cheaply.** `convert(_:to: nil)` in `layout()`
/// answers it, and it costs nothing per frame: the phase lives in a `CABasicAnimation` in the
/// render server, so the geometry is read when AppKit lays the view out and never again. Better
/// than that, the arithmetic is immune to a pane moving under it. With the travel written in a
/// segment's own space as `absolute - origin`, the presented position is `A + (B - A) * phase` with
/// the origin cancelled out, so the crest stays where the window puts it while the inspector slides
/// beneath it over `Motion.inspectorSeconds`. This check passes.
///
/// **What it costs is the rhythm, and that is what stopped it.** One crest over both panes is one
/// crest over roughly twice the track, so either the period doubles, which halves how often
/// anything happens on a line whose whole job is to say something is happening, or the speed
/// doubles, which on a 2560 point window is about 900 points a second and fifteen points a frame at
/// the 60Hz cap this is drawn at, against the five points a frame the cap was chosen for.
///
/// **And making it exact needs the two panes to share a number.** The track has to start where the
/// centre column starts, and the inspector cannot see that: it would have to be published across
/// two views that know nothing about each other, which is `SharedRule`, deleted in `2c373fc` for
/// exactly this reason. Anchoring instead to the window's own leading edge needs nothing shared and
/// is what the check above assumed, but it puts the sidebar inside the track, so between 13 and 32
/// per cent of every cycle is spent with the crest behind a pane that does not draw it, varying
/// with the window and with where the sidebar divider happens to be. That is a mark that nearly
/// lines up rather than one that does.
///
/// So the second option was taken, and it was offered rather than settled for: one rule that reads
/// beats two that nearly agree. The inspector still says an agent is working, in the header spinner
/// it already had, and the window still says it in the sidebar's dots and the status bar's count.
/// `ActivityRuleGallery` keeps a picture of the two-crest version, because a defect that was fixed
/// by deleting something leaves nothing behind to look at.
///
/// # What it costs
///
/// Two small layers, added when the signal appears and left alone: a gradient of one
/// point and a gradient of two, moved by one `CABasicAnimation` each. This body runs when the
/// heartbeat starts or stops, when the width changes, and at no other time. **Nothing here can make
/// the transcript lay out**, which matters more than it used to: the figure is a layer inside a
/// fixed frame in the tab strip's own background, and the transcript below it is never asked a
/// question by any of it.
///
/// The rule was a SwiftUI `.offset` animated by `.animation(_:value:)` before it was a layer, which
/// SwiftUI interpolates on the main thread, re-rendering the whole hosting view's display list once
/// per display frame. Measured on a 120Hz panel with five agents running, four interleaved passes:
/// the rule and the sidebar's dots cost a median of 2.96 seconds of CPU every 15, where the same
/// pair on layers cost 0.13 against a floor of 0.20 with the heartbeat off. Do not put a
/// `repeatForever` back on this rule.
struct ActivityRule: View {
    /// Which figure to draw. The window takes the one the comparison settled on; the gallery is the
    /// only caller that ever names another.
    var variant: BusyRuleVariant = .live

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pulse: BusyPulse { .shared }

    /// **This workspace's turn, not anybody's.** It was `!runningWorkspaceIDs.isEmpty`, so one
    /// agent working anywhere lit the rule over every workspace in the window, and the report was
    /// that the busy indicator shows on all workspaces if any workspace has a running AI. The rule
    /// is drawn once per centre column and the centre column shows one workspace, so it answers
    /// for that one.
    ///
    /// The Ask conversation is scoped to no workspace and has a turn of its own, which is why this
    /// asks the selection rather than a workspace id: reading `runningWorkspaceIDs` alone would
    /// have left Ask permanently dark.
    ///
    /// The clock stays shared. `BusyPulse` still ticks off the whole set, so every rule and dot in
    /// the app agrees on the phase, and what changes here is only which of them is visible. See
    /// `AppModel.runningWorkspaceIDs`.
    private var isRunning: Bool {
        switch app.selection {
        case .ask: app.ask.isRunning
        case .home: false
        default: app.selection.workspaceID.map(app.runningWorkspaceIDs.contains) ?? false
        }
    }

    var body: some View {
        ActivityRuleFigure(variant: variant, isMoving: pulse.isTicking)
            // The signal goes out rather than being cut off. An agent's turn can finish at any
            // moment, including with the crest halfway across, and a lit line vanishing between two
            // frames is a pop. A fifth of a second is short enough that nothing is being claimed
            // after it stopped being true, which is the whole point of `runningWorkspaceIDs`.
            .opacity(isRunning ? 1 : 0)
            .animation(reduceMotion ? nil : Motion.pane, value: isRunning)
            .allowsHitTesting(false)
    }
}

// MARK: - The figure

/// One activity rule, moving or held still, with no opinion about whether anything is running.
///
/// Split from `ActivityRule` so the gallery can draw all three variants in both states without an
/// `AppModel` that has a turn in it, and so the one decision `ActivityRule` makes (is anything
/// running) stays in one place rather than being a parameter this type has to be trusted with.
struct ActivityRuleFigure: View {
    var variant: BusyRuleVariant
    /// False for a rule that is present but still: `Reduce Motion`, and an offscreen render.
    var isMoving: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .clipped()
    }

    @ViewBuilder
    private var content: some View {
        if isMoving {
            // A layer rather than a view, and the still state below is deliberately not one. Only
            // the moving state has anything to gain from Core Animation, and keeping the still one
            // in SwiftUI is what lets `ImageRenderer` still draw a rule that is not moving. See
            // `Snapshot`, which cannot draw an `NSViewRepresentable` at all and paints a yellow
            // placeholder over one.
            MovingActivityRule(variant: variant, epoch: BusyPulse.shared.epoch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            StillActivityRule(variant: variant)
        }
    }
}

// MARK: - Held still

/// What `Reduce Motion` draws, and what every screenshot of a working window photographs.
///
/// **It has to be a mark in its own right.** The brief the crest was drawn to says the indicator
/// must still be clearly visible with motion off, not merely present, and the old figure failed
/// that twice over: a third-strength hairline is what the rule looks like when nothing is
/// happening. So the still figure keeps everything about the crest except the travel. The track is
/// lit at full `trackOpacity`, the crest is parked with its head against the trailing edge, and
/// because the crest's profile is asymmetric that parked shape still points at the place the next
/// word arrives. See `BusyCrest.restingCentre`.
private struct StillActivityRule: View {
    var variant: BusyRuleVariant

    var body: some View {
        switch variant {
        case .crest:
            ZStack(alignment: .bottomTrailing) {
                track
                // Trailing, which is `restingCentre` for every width this rule is drawn at: the
                // centre column is the narrow case and it is 760 points against a crest of 190. A
                // window dragged narrower than a crest loses the far end of the tail off the
                // leading edge, which is the faintest part of the figure.
                crest(BusyCrest.stops()).frame(width: BusyCrest.length)
            }
        case .current:
            // The train has to know how many wavelengths the rule holds, so this one reads its
            // width. A reader rather than a fixed count stretched to fit, because a stretched
            // wavelength is a different figure from the one that moves, and this page exists to be
            // compared against that one.
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    track
                    crest(BusyCrest.waveStops(
                        wavelengths: BusyCrest.wavelengths(alongWidth: geometry.size.width)
                    ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        case .swell:
            // The incumbent, unchanged: the bottom of its own pulse, on the hairline, which is
            // exactly what a screenshot of this rule has shown since it was drawn. It is in the set
            // so the comparison has a control in it, and this is the state where it loses.
            Rectangle()
                .fill(Palette.accent)
                .opacity(BusyRule.opacity(at: BusyRule.resting))
                .frame(maxWidth: .infinity)
                .frame(height: BusyRule.restingHeight)
        }
    }

    /// The lit line the crest rides, which is the whole width and is never dark.
    private var track: some View {
        Rectangle()
            .fill(Palette.accent)
            .opacity(BusyCrest.trackOpacity)
            .frame(maxWidth: .infinity)
            .frame(height: BusyRule.restingHeight)
    }

    /// The crest itself: one point of core on the rule's own line, and two of half strength above
    /// it, so the thickening has an edge rather than a step.
    private func crest(_ stops: [BusyCrest.Stop]) -> some View {
        VStack(spacing: 0) {
            band(stops, scale: BusyCrest.glowShare, height: BusyCrest.glowHeight)
            band(stops, scale: 1, height: BusyRule.restingHeight)
        }
        .frame(height: BusyCrest.thickness)
    }

    private func band(_ stops: [BusyCrest.Stop], scale: Double, height: Double) -> some View {
        LinearGradient(
            stops: stops.map {
                Gradient.Stop(
                    color: Palette.accent.opacity($0.opacity * scale),
                    location: CGFloat($0.location)
                )
            },
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: height)
    }
}

// MARK: - Moving

/// The moving half: two gradient layers carried along the rule, or faded in place.
private struct MovingActivityRule: NSViewRepresentable {
    var variant: BusyRuleVariant
    /// The heartbeat's start, which is the only thing that decides where in its cycle the rule is.
    /// See `BusyPulse.epoch`.
    var epoch: CFTimeInterval

    func makeNSView(context: Context) -> ActivityRuleView {
        let view = ActivityRuleView(frame: .zero)
        view.configure(variant: variant, epoch: epoch)
        return view
    }

    func updateNSView(_ view: ActivityRuleView, context: Context) {
        view.configure(variant: variant, epoch: epoch)
    }

    /// Fills whatever it is given, and asks for nothing: the strip's width is the strip's business
    /// and changes on every frame of a sidebar drag, so there is nothing here for SwiftUI to measure
    /// and nothing the transcript underneath can be asked to lay out for.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: ActivityRuleView, context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Three layers, and the same three whichever variant is drawn: the track, one point of core and
/// two points of glow above it. What changes between the variants is how wide the pair is, what
/// gradient they carry, and whether they are moved or faded.
///
/// **They are siblings rather than a group with two children on purpose.** This view is flipped, so
/// AppKit flips its backing layer's geometry and every direct sublayer is placed from the top the
/// way the rest of this app measures. A layer nested one deeper would be placed inside a parent
/// whose own `isGeometryFlipped` is false, which is one convention too many for two rectangles that
/// always move together. Both are handed the same animation instead, built from the same absolute
/// `beginTime`, and two animations that agree on all three cannot come apart.
final class ActivityRuleView: BusyPulseLayerView {
    /// The crest crosses the centre column in `BusyCrest.period`, which on a 900 point rule is a
    /// little over 300 points a second. At 30 frames that is 10 points a step, and 10 points on a
    /// shape whose steep face is about 40 is a visible stagger; at 60 it is 5, which is inside the
    /// softness of the edge doing the moving. Named as a range rather than left to ProMotion,
    /// because the alternative is 120 frames a second of window server work for a figure that
    /// cannot show the difference.
    private static let travelFrameRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    /// The swell has no position in it at all, so it keeps the cap the whole width fade was already
    /// measured at: it covers 0.68 of full alpha in three quarters of a second, which is 173 levels,
    /// nineteen a step at twelve frames and half as much again through the middle of the ease.
    /// Twenty four halves that.
    private static let fadeFrameRate = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)

    private let track = CALayer()
    private let core = CAGradientLayer()
    private let glow = CAGradientLayer()

    private var variant: BusyRuleVariant = .live
    /// Optional, so the first `configure` always installs. A stored zero would match the epoch a
    /// heartbeat that has never run reports, and the gallery draws exactly that case.
    private var epoch: CFTimeInterval?
    /// What the layers were last laid out and animated for. Negative so the first pass never
    /// matches, since a view that has not been laid out is genuinely zero points wide.
    private var laidOutWidth: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for gradient in [glow, core] {
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
        }
        layer?.addSublayer(track)
        layer?.addSublayer(glow)
        layer?.addSublayer(core)
        applyColors()
    }

    // MARK: Geometry

    /// The rule sits on the last point of this view rather than the first: the strip's own hairline
    /// is drawn at the bottom of the same box, and this is what lights up over it.
    override func layout() {
        super.layout()
        // Written straight onto the model values with actions off, or AppKit's implicit animation
        // would interpolate a window resize into the rule sliding into its new width.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bottom = bounds.height
        track.frame = CGRect(
            x: 0,
            y: bottom - CGFloat(BusyRule.restingHeight),
            width: bounds.width,
            height: CGFloat(BusyRule.restingHeight)
        )
        let width = figureWidth
        core.bounds = CGRect(x: 0, y: 0, width: width, height: CGFloat(BusyRule.restingHeight))
        glow.bounds = CGRect(x: 0, y: 0, width: width, height: CGFloat(BusyCrest.glowHeight))
        core.position = CGPoint(x: restingCentre, y: bottom - CGFloat(BusyRule.restingHeight) / 2)
        glow.position = CGPoint(
            x: restingCentre,
            y: bottom - CGFloat(BusyRule.restingHeight) - CGFloat(BusyCrest.glowHeight) / 2
        )
        CATransaction.commit()

        guard bounds.width != laidOutWidth else { return }
        laidOutWidth = bounds.width
        // The train's gradient is built from the number of wavelengths the rule holds, and the
        // crest's travel runs from one edge to the other, so both are answers to the width.
        // Reinstalling costs nothing that can be seen: the animation's `beginTime` is the absolute
        // epoch, so it comes back at the phase it would have been at anyway.
        applyColors()
        install()
    }

    /// How wide the moving pair is: one crest, one whole train, or the rule itself.
    private var figureWidth: CGFloat {
        switch variant {
        case .crest:
            CGFloat(BusyCrest.length)
        case .current:
            CGFloat(BusyCrest.wavelengths(alongWidth: bounds.width)) * CGFloat(BusyCrest.waveLength)
        case .swell:
            bounds.width
        }
    }

    /// Where the centre of that pair sits with nothing animating it.
    private var restingCentre: CGFloat {
        switch variant {
        case .crest: CGFloat(BusyCrest.restingCentre(alongWidth: bounds.width))
        // The train starts one wavelength to the left and slides back to flush, so at rest it is
        // flush and the rule is covered at both ends of the travel.
        case .current, .swell: figureWidth / 2
        }
    }

    // MARK: Colours

    override func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let accent = resolved(Palette.accentNSColor)
        track.backgroundColor = accent.copy(alpha: BusyCrest.trackOpacity) ?? accent
        // Hidden rather than transparent for the swell: its own core layer is the whole width and
        // is the rule, so a track under it would be a second line at a strength nobody chose.
        track.isHidden = variant == .swell
        let stops = gradientStops
        apply(stops, scale: 1, to: core, accent: accent)
        apply(stops, scale: BusyCrest.glowShare, to: glow, accent: accent)
        CATransaction.commit()
    }

    private var gradientStops: [BusyCrest.Stop] {
        switch variant {
        case .crest:
            BusyCrest.stops()
        case .current:
            BusyCrest.waveStops(wavelengths: BusyCrest.wavelengths(alongWidth: bounds.width))
        // Flat: the swell's strength is in the layer's own opacity, which is what the fade animates.
        case .swell:
            [
                BusyCrest.Stop(location: 0, opacity: 1),
                BusyCrest.Stop(location: 1, opacity: 1),
            ]
        }
    }

    private func apply(
        _ stops: [BusyCrest.Stop], scale: Double, to gradient: CAGradientLayer, accent: CGColor
    ) {
        gradient.colors = stops.map { (accent.copy(alpha: $0.opacity * scale) ?? accent) as Any }
        gradient.locations = stops.map { NSNumber(value: $0.location) }
    }

    // MARK: The animation

    /// Guarded, because `updateNSView` runs on every pass SwiftUI makes over this view and a window
    /// being resized makes a great many of them. Reinstalling an animation that is already correct
    /// would reset nothing visible, since the phase comes from an absolute epoch, but it would ask
    /// the render server to rebuild it for no reason.
    func configure(variant: BusyRuleVariant, epoch: CFTimeInterval) {
        var changed = false
        if variant != self.variant {
            self.variant = variant
            changed = true
            applyColors()
            needsLayout = true
        }
        if epoch != self.epoch {
            self.epoch = epoch
            changed = true
        }
        guard changed else { return }
        install()
    }

    private func install() {
        guard let epoch else { return }

        // The model values are the still figure, so a layer whose animation has not arrived yet
        // draws what `Reduce Motion` would rather than whatever the last frame left behind.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.opacity = variant == .swell ? Float(BusyRule.opacity(at: BusyRule.resting)) : 1
        glow.opacity = variant == .swell ? Float(glowStrength(at: BusyRule.resting)) : 1
        CATransaction.commit()

        switch variant {
        case .crest, .current:
            let range = travel
            for target in [core, glow] {
                install(
                    slide(from: range.lowerBound, to: range.upperBound, period: period),
                    on: target, key: "travel", beginAt: epoch
                )
            }
        case .swell:
            // Both ends of the fade, and the thickness envelope read through `BusyRule.height`
            // rather than restated: the glow is the two points the rule grows by, so how strongly
            // it is drawn is where that height has got to.
            install(
                pulse(
                    "opacity",
                    from: BusyRule.opacity(at: 0), to: BusyRule.opacity(at: 1),
                    period: BusyRule.period, frameRate: Self.fadeFrameRate
                ),
                on: core, key: "travel", beginAt: epoch
            )
            install(
                pulse(
                    "opacity",
                    from: glowStrength(at: 0), to: glowStrength(at: 1),
                    period: BusyRule.period, frameRate: Self.fadeFrameRate
                ),
                on: glow, key: "travel", beginAt: epoch
            )
        }
    }

    /// Where the pair travels between, for the width it was last laid out at.
    private var travel: ClosedRange<CGFloat> {
        switch variant {
        case .crest:
            let range = BusyCrest.travel(alongWidth: bounds.width)
            return CGFloat(range.lowerBound)...CGFloat(range.upperBound)
        // One wavelength, and the same one whatever the rule is: a train that closes on itself
        // travelling exactly its own period is a figure with no seam and no dependence on width.
        case .current, .swell:
            let centre = figureWidth / 2
            return (centre - CGFloat(BusyCrest.waveLength))...centre
        }
    }

    private var period: TimeInterval {
        variant == .crest ? BusyCrest.period : BusyCrest.wavePeriod
    }

    /// How strongly the swell's glow is drawn at a point in the pulse, from the thickness the core
    /// figure says the rule has reached.
    private func glowStrength(at pulse: Double) -> Double {
        let span = BusyRule.peakHeight - BusyRule.restingHeight
        guard span > 0 else { return 0 }
        return (BusyRule.height(at: pulse) - BusyRule.restingHeight) / span * BusyCrest.glowShare
    }

    /// One crossing, in a straight line and in one direction.
    ///
    /// Linear and not autoreversed, which is the whole difference from `pulse`: an eased crest
    /// would slow down in the middle of the rule, where it is most visible, and a reversed one
    /// would carry the head backwards through its own tail once a cycle. What moves is `position.x`
    /// and nothing else, so the render server is translating two rectangles it already has.
    private func slide(from: CGFloat, to: CGFloat, period: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = period
        animation.preferredFrameRateRange = Self.travelFrameRate
        return animation
    }
}
