import SwiftUI
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
/// # What it costs
///
/// A `transform` on one 160 by 1 layer per segment, handed to Core Animation when the pass starts
/// and interpolated by the render server. This body runs twice in a four and a half second cycle,
/// because `BusyPulse.isSweeping` is published rather than derived from the tick. Nothing is
/// repainted per frame: the gradient is a fixed one that is moved, not a moving one that is
/// redrawn, which is the mistake the study named for this variation specifically.
struct RuleSweep: View {
    /// Which piece of the rule this is. It decides where along the rule the light enters, and
    /// nothing else: both segments run the same animation over the same distance at the same
    /// moment, which is what makes the crossing continuous.
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
    private static let length: CGFloat = 160

    /// What the rule holds while an agent is working and nothing is moving: Reduce Motion, or the
    /// window behind another app. A tint rather than nothing at all, because the signal has to
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
            // The signal goes out rather than being cut off. A turn can finish at any moment,
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
            light
        } else {
            Rectangle()
                .fill(Palette.accent)
                .opacity(Self.restingOpacity)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.hairline)
        }
    }

    private var light: some View {
        let origin = segment == .tabStrip ? 0 : rule.inspectorOrigin
        let isSweeping = pulse.isSweeping

        return LinearGradient(
            colors: [.clear, Palette.accent, .clear], startPoint: .leading, endPoint: .trailing
        )
        .frame(width: Self.length, height: Metrics.hairline)
        // Both ends are off the rule, which is what lets the return leg be a jump rather than a
        // second animation: at the start of a pass the light is entirely past the window's leading
        // edge and at the end of one it is entirely past the trailing edge, so the frame it snaps
        // back on is a frame in which it is not on screen.
        .offset(x: isSweeping ? rule.length - origin : -Self.length - origin)
        // The pass is animated and the return is not. `.animation(_:value:)` reads the animation
        // at the moment the value changes, so the same expression gives the travel its curve on
        // the way out and gives the reset none on the way back.
        .animation(isSweeping ? Motion.sweep : nil, value: isSweeping)
    }
}
