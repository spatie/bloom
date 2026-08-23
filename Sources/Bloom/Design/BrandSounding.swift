import AppKit
import SwiftUI

/// Rings going out from the mark, the way a sounding goes out from a boat.
///
/// The welcome window's second screen draws a sounding line down the left of the checks: a
/// hairline in the accent that descends as far as Bloom has read, so a glance says how deep it
/// has got. This is where that line comes from. The greeting rings a sounding out across the
/// water, and the screen after it draws what came back. The metaphor is not decoration bolted
/// onto a splash screen, it is the same one the checks already run on, which is the only reason
/// there is a ring here rather than a shimmer or a glow.
///
/// The About window's lesson is what fixes the shape. A soft field translating is the one motion
/// the eye cannot catch, because nothing in it gives a reference; `BrandWater` says so with the
/// measurement that cost an afternoon. A ring has an edge, so it can be caught, and it is the one
/// thing that can move slowly here and still be seen moving. It is also the one thing that ends:
/// a ring reaches the wall of the plinth and is gone, which is why three of them on a nine second
/// cycle read as water rather than as a loading indicator going round.
///
/// Core Animation, for `BrandWater`'s reasons and at `BrandWater`'s frame rate. The cap is what
/// keeps the render server from honouring this display's full ProMotion rate on a window somebody
/// leaves open: measured there at about forty percent of one core in WindowServer uncapped
/// against seven capped. A ring travels about twelve points a second at its fastest, so at twelve
/// frames a second it advances a point a frame, which on a stroke this soft is under what the
/// edge can show anyway.
struct BrandSounding: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far out the rings are allowed to travel, in points, from the centre of the mark.
    let reach: CGFloat

    func makeNSView(context: Context) -> BrandSoundingView { BrandSoundingView() }

    func updateNSView(_ view: BrandSoundingView, context: Context) {
        view.reach = reach
        // Removed, not slowed, which is the rule every call site of `Motion` follows. With Reduce
        // Motion on there is no ring at all rather than a ring held still: unlike the water's
        // pools, a ring at rest is a circle drawn round the mark, and a circle nobody asked for
        // is worse than nothing.
        view.setMoving(!reduceMotion)
    }
}

final class BrandSoundingView: NSView {
    var reach: CGFloat = 200 {
        didSet { if reach != oldValue { needsLayout = true } }
    }

    /// Three, and the count is the cycle. One ring alone reads as a pulse and has an obvious
    /// silence after it; three at a third of a cycle apart mean there is always one on its way
    /// out and one just leaving, so the water is never empty and never crowded.
    private let rings: [CAShapeLayer] = (0..<3).map { _ in BrandSoundingView.ring() }
    private var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for ring in rings { layer?.addSublayer(ring) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// One ring: Shallow `#9BE9DC`, the brighter of the water's two pools and what a settled check
    /// is ticked in, drawn as a stroke and nothing else. Unfilled, because a filled disc expanding
    /// out of the mark would wash the wordmark under it once every three seconds.
    private static func ring() -> CAShapeLayer {
        let ring = CAShapeLayer()
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor(rgb: 0x9BE9DC).cgColor
        ring.lineWidth = 1
        ring.opacity = 0
        return ring
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Every ring is drawn at the start radius and grown by a transform rather than by its
        // path, so the whole travel is one animatable property the render server owns and nothing
        // is re-pathed per frame.
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let box = CGRect(x: centre.x - Self.start, y: centre.y - Self.start,
                         width: Self.start * 2, height: Self.start * 2)
        for ring in rings {
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: box, transform: nil)
        }
        CATransaction.commit()
        applyMotion()
    }

    /// Where a ring starts, in points: just outside the mark, so the first thing it does is leave
    /// the mark rather than appear on top of it.
    private static let start: CGFloat = 40
    private static let period: CFTimeInterval = 9
    private static let frameRate = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)

    func setMoving(_ wanted: Bool) {
        moving = wanted
        applyMotion()
    }

    private func applyMotion() {
        for ring in rings { ring.removeAllAnimations() }
        guard moving, bounds.width > 0 else { return }
        for (index, ring) in rings.enumerated() {
            let phase = Self.period / CFTimeInterval(rings.count) * CFTimeInterval(index)
            expand(ring, phase: phase)
        }
    }

    private func expand(_ ring: CAShapeLayer, phase: CFTimeInterval) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = max(reach, Self.start * 1.5) / Self.start
        // Eased out rather than linear, because that is what a ring on water does: it leaves fast
        // and slows as it spreads. Linear read as a shape being scaled, which is what it is.
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)

        // The ring is never at full strength at either end of its travel. It rises out of nothing
        // in the first tenth so it is not seen appearing, and it is gone well before the wall of
        // the plinth so it is never seen being clipped.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.30, 0.14, 0]
        fade.keyTimes = [0, 0.10, 0.45, 1]

        let sounding = CAAnimationGroup()
        sounding.animations = [grow, fade]
        sounding.duration = Self.period
        sounding.repeatCount = .infinity
        sounding.preferredFrameRateRange = Self.frameRate
        // Wound forward rather than delayed, so the window opens onto a sounding already under
        // way instead of onto three seconds of nothing followed by a ring.
        sounding.timeOffset = phase
        ring.add(sounding, forKey: "sounding")
    }
}
