import SwiftUI
import QuartzCore
import BloomCore

/// The window's shared rule, brightening and dimming while an agent is working.
///
/// # What this replaced, and why
///
/// A light used to travel this rule: a 160 point gradient crossing it in three seconds. What killed
/// it was contrast rather than motion. The light was a one point hairline in the accent colour on a
/// rule that is already the accent at `BusyRule.restingOpacity`, so the mark and the line under it
/// were the same hue and on pale chrome there was nothing to see. Five replacements were drawn side
/// by side and the owner took the plainest: no light, no travel, the whole width moving at once.
///
/// # Which rule, and why this one
///
/// The rule at y=83, the one that closes off the tab strip, and **the rule at y=52 does not
/// exist.** The study that drew the five variations called it "the only line in the window that
/// crosses all three columns"; sampled on a two times capture at 1200 by 760, at y=52 the sidebar
/// is flat chrome, the centre column is the tab strip's recess tint, and only the inspector carries
/// a hairline. Putting the signal there is not using an existing rule, it is adding one. The
/// sidebar is out for the same reason, measured the same way.
///
/// # What it costs
///
/// One `CABasicAnimation` on the `opacity` of one hairline layer per segment, added when the signal
/// appears and never touched again, so this body runs when the heartbeat starts or stops and at no
/// other time.
///
/// The rule was a SwiftUI `.offset` animated by `.animation(_:value:)` before it was a layer, which
/// SwiftUI interpolates on the main thread, re-rendering the whole hosting view's display list once
/// per display frame. Measured on a 120Hz panel with five agents running, four interleaved passes:
/// the rule and the sidebar's dots cost a median of 2.96 seconds of CPU every 15, where the same
/// pair on layers cost 0.13 against a floor of 0.20 with the heartbeat off. Do not put a
/// `repeatForever` back on this rule.
struct RulePulse: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pulse: BusyPulse { .shared }

    /// Read from the one observable set, not from a flag of this view's own. See
    /// `AppModel.runningWorkspaceIDs`.
    private var isRunning: Bool { !app.runningWorkspaceIDs.isEmpty }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .clipped()
            // The signal goes out rather than being cut off. An agent's turn can finish at any
            // moment, including with the rule at the top of its pulse, and a full accent line
            // across the window vanishing between two frames is a pop. A fifth of a second is
            // short enough that nothing is being claimed after it stopped being true, which is the
            // whole point of `runningWorkspaceIDs`.
            .opacity(isRunning ? 1 : 0)
            .animation(reduceMotion ? nil : Motion.pane, value: isRunning)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var content: some View {
        if pulse.isTicking {
            // A layer rather than a view, and the resting state below is deliberately not one.
            // Only the moving state has anything to gain from Core Animation, and keeping the
            // still one in SwiftUI is what lets `ImageRenderer` still draw a rule that is not
            // pulsing. See `Snapshot`, which cannot draw an `NSViewRepresentable` at all.
            PulsingRule(epoch: pulse.epoch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Rectangle()
                .fill(Palette.accent)
                .opacity(BusyRule.restingOpacity)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.hairline)
        }
    }
}

// MARK: - The moving figure

/// The moving half of `RulePulse`: a hairline layer that fades up and back.
private struct PulsingRule: NSViewRepresentable {
    /// The heartbeat's start, which is the only thing that decides where in its pulse the rule is.
    /// See `BusyPulse.epoch`.
    var epoch: CFTimeInterval

    func makeNSView(context: Context) -> PulsingRuleView {
        let view = PulsingRuleView(frame: .zero)
        view.configure(epoch: epoch)
        return view
    }

    func updateNSView(_ view: PulsingRuleView, context: Context) {
        view.configure(epoch: epoch)
    }

    /// Fills whatever it is given. The strip and the inspector's tab row are different widths, and
    /// neither of them has to know the other's any more, so there is nothing here for SwiftUI to
    /// measure.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulsingRuleView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// One accent hairline on a layer, under a repeating fade.
final class PulsingRuleView: BusyPulseLayerView {
    /// Capped, but not at the twelve frames a second `PulsingDot` and `BrandWater` settled on, and
    /// the reason is that comment's own arithmetic rather than a different taste. The water is
    /// capped that hard because its fastest brightness change is about two of two hundred and
    /// fifty five levels a second, so a twelfth of a second is a sixth of a level and nothing a
    /// gradient could show. This fade covers 0.68 of full alpha in three quarters of a second,
    /// which is a hundred and seventy three levels: nineteen a step at twelve frames, and half as
    /// much again through the middle of the ease, on a line as wide as the window. Twenty four
    /// halves that. What it asks of WindowServer is a one point strip rather than the field of
    /// soft gradients that measurement caught costing forty percent of a core uncapped, and it is
    /// still a cap, which is the whole reason to name a range instead of letting ProMotion have
    /// it.
    private static let frameRate = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)

    private let rule = CALayer()
    private var epoch: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(rule)
        applyColors()
    }

    override func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rule.backgroundColor = resolved(NSColor(Palette.accent))
        CATransaction.commit()
    }

    /// The rule sits on the last point of this view rather than the first: the strip's own hairline
    /// is drawn at the bottom of the same box, and this is what lights up over it.
    override func layout() {
        super.layout()
        // Written straight onto the layer's model frame with actions off, or AppKit's implicit
        // animation would interpolate a window resize into the rule sliding into its new width.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rule.frame = CGRect(
            x: 0,
            y: bounds.height - Metrics.hairline,
            width: bounds.width,
            height: Metrics.hairline
        )
        CATransaction.commit()
    }

    /// Guarded, because `updateNSView` runs on every pass SwiftUI makes over this view and a
    /// window being resized makes a great many of them. Reinstalling an animation that is already
    /// correct would reset its phase, and the phase is what puts this rule on the same beat as
    /// every dot in the window.
    func configure(epoch: CFTimeInterval) {
        guard epoch != self.epoch else { return }
        self.epoch = epoch
        install()
    }

    private func install() {
        // The model value is the resting figure, so a layer whose animation has not arrived yet
        // draws the rule at the strength it would rest at rather than at full accent. Written with
        // actions off, or AppKit interpolates its way there.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rule.opacity = Float(BusyRule.opacity(at: BusyRule.resting))
        CATransaction.commit()

        // The dot's pulse with the rule's ends, which is what `BusyRule.period` being
        // `BusyDot.period` is for: the rule is at the top of its brightening on the frame every
        // dot in the window is at the top of its swell. Both begin at their resting figure, and
        // the other way round was never available: an animation that began at full accent would
        // put the frozen rule and the first frame of the moving one at opposite ends, and the
        // frozen one is what `Reduce Motion` and every screenshot draw.
        install(
            pulse(
                "opacity",
                from: BusyRule.opacity(at: 0), to: BusyRule.opacity(at: 1),
                period: BusyRule.period, frameRate: Self.frameRate
            ),
            on: rule, key: "pulse", beginAt: epoch
        )
    }
}
