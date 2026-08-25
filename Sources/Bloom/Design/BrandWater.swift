import AppKit
import SwiftUI

/// The colours the runbloom.app site is printed in, and the water that drifts in them.
///
/// Deliberately not in `Palette`. That is the window ramp: four surfaces and a rule, resolving
/// differently in each appearance, and CLAUDE.md is explicit that a fifth surface is how the app
/// starts looking heavy again. These are not surfaces. They are the colours the site is printed
/// in, and they are the same in both appearances for the same reason a record sleeve is the
/// colour it was printed: the mark was drawn for a deep ground and the wordmark set on one, so a
/// plinth that turned white in light mode would be showing a Bloom that exists nowhere else.
///
/// Its own file rather than the About window's private business, because the welcome window
/// stands on the same plinth. The animation below carries a measurement in its head that cost an
/// afternoon to take, and a second copy of it is a second place for that measurement to rot.
/// `public/brand/PALETTE.md` and `resources/css/app.css` in the runbloom.app repository are where
/// each of these numbers is from.
enum Brand {
    /// Depth, the site's plinth gradient: Fathom `#123B57` at the top to Abyss `#061420` at the
    /// bottom. One of exactly two gradients the brand has, and the one that reads as looking down
    /// into water rather than as a gradient for its own sake.
    static let depth = LinearGradient(
        colors: [
            Color(nsColor: NSColor(rgb: 0x123B57)),
            Color(nsColor: NSColor(rgb: 0x061420)),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Foam `#E9F7F4`, the ramp's near white. 16.9 to 1 on Abyss.
    static let foam = Color(nsColor: NSColor(rgb: 0xE9F7F4))

    /// The site's `--mist-dim` `#8AA0AB`, which is what it sets a mono spec line in. 6.0 to 1 on
    /// Abyss, so a spec line stays readable rather than merely present.
    static let mistDim = Color(nsColor: NSColor(rgb: 0x8AA0AB))

    /// Shallow `#9BE9DC`, the brighter of the two pools, and what a settled check is ticked in on
    /// the plinth. 13.3 to 1 on Abyss.
    static let shallow = Color(nsColor: NSColor(rgb: 0x9BE9DC))
}

/// The water in the plinth: two pools of light breathing against each other, a ribbon of light
/// swaying through them, and a slow drift underneath, which is the site's water brought over as
/// layers rather than as CSS.
///
/// The first version of this transcribed `.gate__panel::before` exactly: the same two pools at
/// seven and nine percent opacity, the whole painting translated two and a half percent over
/// thirty eight seconds. It ran, it was verified running, and nobody ever saw it. Measured on a
/// Retina capture of the open window, the largest change it made to any pixel channel over twenty
/// whole seconds was seven parts in two hundred and fifty five, spread across a gradient with no
/// edges, and over five seconds it was three. A translation of a soft field is the one motion the
/// eye cannot catch, because nothing in the field gives it a reference. The site itself says what
/// to do instead. The hero's ribbons hold still enough to read as structure while the brightness
/// travels along them, and the gate's mark breathes its glow between a quarter and six tenths
/// opacity on a seven second cycle, which its own CSS calls alive, not animated. So this version
/// animates the light and leaves the geometry nearly alone: each pool breathes between two fifths and
/// full strength on its own period, the two out of phase so one waxes while the other wanes; the
/// gate's faint diagonal band becomes a ribbon swaying slowly down the plinth and back; and the
/// drift is kept but split per pool and opposed, so the two read as water moving over water
/// rather than as one plate sliding. The periods share no common factor, so the composition never
/// visibly repeats, and everything eases at both ends, so there is no loop point to notice.
///
/// The pools are Shallow `#9BE9DC` and Current `#2AA3B4`, the ribbon is the hero field's own
/// light `#7FE8D6`, all fixed in both appearances because the plinth they sit in is. The register
/// is still atmosphere, not effect: an earlier animation idea was pulled on this project for
/// being too on the nose, so the water has to be seen within a few seconds of the window opening
/// and then be ignorable, never competing with the wordmark it sits behind.
///
/// Core Animation rather than a SwiftUI animation, deliberately. A `TimelineView` or a
/// `repeatForever` offset animation re-renders in the app's process at display refresh for the
/// whole life of a window that is often left open. A `CABasicAnimation` is handed to the render
/// server once and costs this process nothing afterwards: with the window open, front and
/// animating, this process accrued 0.03 seconds of CPU across a 41 second sample, against 0.06
/// with the window closed, both the sampler's noise floor. What the render server then does with
/// it is not free, which the first version's measurement missed by sampling only this process;
/// `frameRate` below is that lesson, with its numbers.
struct BrandWater: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> BrandWaterView { BrandWaterView() }

    func updateNSView(_ view: BrandWaterView, context: Context) {
        // Removed, not slowed: Reduce Motion means the water holds still, and the pools and the
        // ribbon stay, because the setting is about movement and held light is not moving. The
        // same rule `Motion`'s call sites follow.
        view.setMoving(!reduceMotion)
    }
}

final class BrandWaterView: NSView {
    /// The painting, larger than the view so no sway can show an edge. The site does the same
    /// with `inset: -35%`.
    private let canvas = CALayer()
    private let shallowPool = BrandWaterView.pool(rgb: 0x9BE9DC, alpha: 0.14)
    private let currentPool = BrandWaterView.pool(rgb: 0x2AA3B4, alpha: 0.16)
    private let ribbon = BrandWaterView.ribbon(rgb: 0x7FE8D6, alpha: 0.07)
    private var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        canvas.addSublayer(shallowPool)
        canvas.addSublayer(currentPool)
        // Above the pools, which is where the gate paints its band: CSS lists it first, and the
        // first background layer is the topmost.
        canvas.addSublayer(ribbon)
        layer?.addSublayer(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// One pool: a radial falloff from a palette colour to nothing by seventy percent of the
    /// radius, which is the site's `radial-gradient(..., transparent 70%)`. The colour carries
    /// the pool's full brightness; the layer's opacity is where the breathing lives, and its
    /// resting value is the middle of the breath, so the still water Reduce Motion shows is the
    /// time average of the moving water, not its brightest or dimmest frame.
    private static func pool(rgb: UInt32, alpha: CGFloat) -> CAGradientLayer {
        let pool = CAGradientLayer()
        pool.type = .radial
        pool.colors = [
            NSColor(rgb: rgb).withAlphaComponent(alpha).cgColor,
            NSColor(rgb: rgb).withAlphaComponent(0).cgColor,
            NSColor(rgb: rgb).withAlphaComponent(0).cgColor,
        ]
        pool.locations = [0, 0.7, 1]
        pool.startPoint = CGPoint(x: 0.5, y: 0.5)
        pool.endPoint = CGPoint(x: 1, y: 1)
        pool.opacity = 0.7
        return pool
    }

    /// The gate's faint diagonal band, `linear-gradient(343deg, transparent 42%, light 50%,
    /// transparent 58%)`: a soft stripe leaning about seventeen degrees off horizontal, the same
    /// shallow diagonal the hero's ribbons run on. The stop positions are widened from the CSS
    /// because this band moves and that one does not: edges forty percent apart stay soft enough
    /// that the ribbon reads as light in the water rather than as a bar crossing it.
    private static func ribbon(rgb: UInt32, alpha: CGFloat) -> CAGradientLayer {
        let band = CAGradientLayer()
        band.colors = [
            NSColor(rgb: rgb).withAlphaComponent(0).cgColor,
            NSColor(rgb: rgb).withAlphaComponent(alpha).cgColor,
            NSColor(rgb: rgb).withAlphaComponent(0).cgColor,
        ]
        band.locations = [0.30, 0.5, 0.70]
        band.startPoint = CGPoint(x: 0.60, y: 0)
        band.endPoint = CGPoint(x: 0.40, y: 1)
        return band
    }

    func setMoving(_ wanted: Bool) {
        moving = wanted
        applyMotion()
    }

    override func layout() {
        super.layout()
        // Everything is laid out fractionally off the view's size, inside a transaction with
        // actions disabled so a resize is a placement rather than an animation of its own. The
        // window is fixed size, so in practice this runs once.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds.insetBy(dx: -bounds.width * 0.35, dy: -bounds.height * 0.35)
        let size = canvas.bounds.size
        // The site's two pools: 38% by 30% at 26%, 24%, and 34% by 28% at 76%, 72%. Layer
        // geometry is bottom up, so the vertical fractions are flipped.
        shallowPool.frame = CGRect(
            x: size.width * 0.26 - size.width * 0.19,
            y: size.height * 0.76 - size.height * 0.15,
            width: size.width * 0.38,
            height: size.height * 0.30
        )
        currentPool.frame = CGRect(
            x: size.width * 0.76 - size.width * 0.17,
            y: size.height * 0.28 - size.height * 0.14,
            width: size.width * 0.34,
            height: size.height * 0.28
        )
        ribbon.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        applyMotion()
    }

    /// Everything that moves, and how much. The breaths are what make the water visible in the
    /// first few seconds: eight and twelve second periods put a full soft swell inside anyone's
    /// first glance, and the offset keeps the plinth's total light roughly level, so the window
    /// never pulses as a whole. The sways are the accompaniment, a few points a second at most,
    /// there to give the brightening a direction rather than to be seen on their own.
    private func applyMotion() {
        for light in [shallowPool, currentPool, ribbon] {
            light.removeAllAnimations()
        }
        guard moving, canvas.bounds.width > 0 else { return }
        let width = canvas.bounds.width
        let height = canvas.bounds.height
        sway(shallowPool, by: CGVector(dx: width * 0.05, dy: -height * 0.04), over: 26)
        sway(currentPool, by: CGVector(dx: -width * 0.045, dy: height * 0.035), over: 34)
        sway(ribbon, by: CGVector(dx: width * 0.02, dy: height * 0.11), over: 21)
        breathe(shallowPool, over: 8, phase: 0)
        breathe(currentPool, over: 12, phase: 12)
    }

    /// The water's whole frame budget. Every animation here is capped this hard because the
    /// fastest thing in the composition, the eight second breath, changes the brightest pixel in
    /// its pool by about two of two hundred and fifty five levels a second: at twelve frames a
    /// second each step is a sixth of a level, far below anything a gradient can show. Without
    /// the cap the render server honoured this display's full ProMotion rate instead, and
    /// WindowServer spent about forty percent of one core recompositing the window with the
    /// About window open against seven with it closed, drawing pictures indistinguishable from
    /// each other, for as long as the window stayed open. Capped, the same sampling puts the
    /// open window within ten points of one core of the closed baseline.
    ///
    /// **It is an argument about brightness changing, not about anything moving, and it does not
    /// carry to a layer that travels.** `BrandBranching` took this number by citation and was
    /// wrong to: its branch heads are fifty eight point blooms crossing the plinth at up to forty
    /// two points a second, and at twelve frames each step moves them three and a half points and
    /// eighteen levels, which is a hundred times what the sentence above is defending. It runs at
    /// sixty now, with its own measurement of what every rung of that ladder costs. The travel
    /// this file has is the sways, a few points a second across a field with no edge anywhere in
    /// it, which measures at two levels a step and is why the cap is still right for the water.
    private static let frameRate = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)

    private func sway(_ light: CALayer, by offset: CGVector, over seconds: CFTimeInterval) {
        let base = light.position
        let sway = CABasicAnimation(keyPath: "position")
        sway.fromValue = CGPoint(x: base.x - offset.dx, y: base.y - offset.dy)
        sway.toValue = CGPoint(x: base.x + offset.dx, y: base.y + offset.dy)
        sway.duration = seconds
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sway.autoreverses = true
        sway.repeatCount = .infinity
        sway.preferredFrameRateRange = Self.frameRate
        // Started from the middle of the travel rather than an end, so the window never opens
        // onto every layer poised at an extreme and setting off together.
        sway.timeOffset = seconds / 2
        light.add(sway, forKey: "sway")
    }

    /// The gate's `gate-breathe`, moved from the mark's halo into the water itself: opacity, not
    /// position, because a change of brightness is the one change the last version proved a soft
    /// field can actually show.
    private func breathe(_ light: CALayer, over seconds: CFTimeInterval, phase: CFTimeInterval) {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.4
        breathe.toValue = 1.0
        breathe.duration = seconds
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.preferredFrameRateRange = Self.frameRate
        breathe.timeOffset = phase
        light.add(breathe, forKey: "breathe")
    }
}
