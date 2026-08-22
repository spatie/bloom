import AppKit
import SwiftUI
import BloomCore

/// The window behind "About Bloom".
///
/// It replaces `NSApplication.orderFrontStandardAboutPanel`, which drew an icon, the word Bloom
/// and a version number. Every one of those is true and none of them belongs to this app in
/// particular: that panel is the same panel in every Mac application, and the only thing it can be
/// given beyond the bundle's own keys is a paragraph of credits. No mark, no typeface, no ground.
///
/// Bloom has a site at runbloom.app built on one ramp and one pair of typefaces, and an About
/// window is the one window small enough to be that site and still be a Mac window. So this is the
/// site's own furniture: the Depth plinth with the site's water drifting in it, the mark on it,
/// the name set in a serif, a mono spec line under it, and below the rule the site's makers
/// section, ending in the footer's credit strip. `public/brand/PALETTE.md` and
/// `resources/css/app.css` in the runbloom.app repository are where each of those numbers is from.
///
/// One instance, kept here. `isReleasedWhenClosed` defaults to true for a window built in code, so
/// without the line below the second visit would message a window that had been deallocated by the
/// first close.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    /// Opens it, or brings the one that is already open forward.
    ///
    /// Deliberately not re-centred on the second visit. A window the user has dragged somewhere
    /// and left open should come forward where they put it; jumping back to the middle of the
    /// screen under their pointer reads as a second window having opened.
    static func show() {
        let existing = window ?? make()
        window = existing
        existing.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let host = NSHostingView(rootView: AboutView())
        // Asked for rather than written down, so the numbers in `AboutView` are the only ones and
        // a change to its padding cannot leave the window an inch too tall.
        let size = host.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // No `.resizable` and no `.miniaturizable`: there is nothing in here to resize and
            // nothing to come back to. `.fullSizeContentView` is what lets the plinth run up
            // behind the title bar, which it has to do, because the alternative is a strip of flat
            // window background above a gradient and a visible seam between the two.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Set even though it is hidden: it is what the Window menu and the accessibility hierarchy
        // call this window.
        window.title = "About Bloom"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The title bar is transparent and carries no title, so there is no strip left to drag the
        // window by. The plinth becomes that strip instead.
        window.isMovableByWindowBackground = true
        // Absent rather than drawn greyed out. AppKit still draws both buttons for a window whose
        // style mask lacks them, and two dead circles beside a live one is the sort of detail an
        // About window is judged on.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = host
        window.setContentSize(size)
        window.center()
        return window
    }
}

/// What that window draws. Every number in it lives here; every sentence and every address lives
/// in `Maker` and `BuildIdentity`, because a string typed into this file is a string nothing in
/// `Tests/BloomCoreTests` can hold still.
private struct AboutView: View {
    /// Wide enough that the product summaries set beside their marks without an orphaned line,
    /// and no wider: the window is a column of centred things and a short list, and surplus width
    /// reads as a dialog that forgot its content. 360 was the width before the makers section
    /// arrived and every summary broke mid-phrase at it; 420 held until the marks arrived and
    /// their column pushed Flare's summary into a two word second line.
    private static let width: CGFloat = 460

    /// The app's own icon at the size the site's closing section draws the mark at, scaled for a
    /// window rather than a page. Read out of the running bundle rather than shipped a second time
    /// here, so the window can never show a mark the app has stopped using.
    private static let markSize: CGFloat = 96

    /// The Spatie lockup is a fixed 2.33:1 plate, so only its height is set and the width follows.
    /// Sized off the mono line it sits in, the way `.spatie-badge` on the site is sized in `em`
    /// off `.footer__credit`.
    private static let badgeHeight: CGFloat = 19

    var body: some View {
        VStack(spacing: 0) {
            plinth
            rule
            makers
            rule
            credit
        }
        .frame(width: Self.width)
    }

    private var rule: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: Metrics.hairline)
    }

    // MARK: The plinth

    private var plinth: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.markSize, height: Self.markSize)
                // The site seats every screenshot and the closing mark on a shadow rather than
                // letting them float on the ground. `.shot` is `0 30px 80px -40px rgb(0 0 0 /
                // 70%)`; this is the same shadow at a window's scale.
                .shadow(color: .black.opacity(0.55), radius: 16, y: 9)
                .accessibilityHidden(true)

            // Serif, light, and tracked in, which is `.display` on the site: Newsreader at weight
            // 300 with -0.022em of letter spacing. New York is what `design: .serif` resolves to
            // on macOS and is the closest face this machine has to Newsreader, so the wordmark
            // reads as the same wordmark rather than as the system font in a larger size.
            Text(verbatim: "Bloom")
                .font(.system(size: 34, weight: .light, design: .serif))
                .tracking(-0.75)
                .foregroundStyle(Self.foam)
                .padding(.top, Metrics.spacingWide)

            // The site's `.hero__spec`: mono, small, dimmed, with a middle dot between the parts.
            Text(versionLine)
                .font(Typo.codeSmall)
                .foregroundStyle(Self.mistDim)
                .padding(.top, Metrics.spacing)

            // The app's own address, up here rather than in the footer, and in exactly one of
            // the two. This is the identity block, and the person most likely to want this link
            // is hunting for the site, the changelog or the release notes, which is a hunt that
            // starts at the version line and stops when an address appears under it. The footer
            // is Spatie's signature, and a second address beside spatie.be would turn the
            // signature into a link list. `linkInverted` because the plinth is fixed dark
            // artwork in both appearances and the ramp's link colours are picked against the
            // window surfaces, not against Abyss.
            Link(AppSite.host, destination: AppSite.url)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.linkInverted)
                .underline()
                .padding(.top, Metrics.spacingWide + Metrics.spacingSmall)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 38)
        .padding(.bottom, 26)
        .background {
            // `.ignoresSafeArea` because this is the view builder overload of `background`,
            // which respects the safe area that the ShapeStyle overload ignores by default.
            // Without it the plinth stops at the title bar and leaves a strip of flat window
            // background above the gradient, which is exactly the seam `.fullSizeContentView`
            // exists to prevent. The clip is for the water, which is painted larger than the
            // plinth so its drift never shows an edge.
            ZStack {
                Self.depth
                PlinthWater()
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        }
    }

    /// What the AppKit panel used to print under the name, except honest about which build it is.
    ///
    /// Never a literal, and never the two version keys read raw. `Resources/Info.plist` carries a
    /// fixed `0.1.0 (1)` that only the release workflow overwrites, so reading those keys made
    /// every build on this machine claim a version that had never been released. `BuildIdentity`
    /// is the type that knows the difference; see its head.
    private var versionLine: String {
        BuildIdentity.read(from: .main).line
    }

    // MARK: The makers

    /// The site's makers section at a window's scale: who Spatie is, then the products, the same
    /// three in the same order as the download email the site sends. On the reading ground rather
    /// than the chrome, because this is the part of the window that is read rather than read off,
    /// and the strip below keeps the chrome colour so the two still divide the way a content pane
    /// and a status bar do.
    private var makers: some View {
        VStack(spacing: 0) {
            // The site's footer credit, in the site's words and the site's order. The mark rather
            // than the name, because that is how Spatie signs the page it made.
            HStack(spacing: Metrics.spacing) {
                Text("Made by")
                badge
                Text("in Antwerp, Belgium")
            }
            .font(Typo.codeSmall)
            .foregroundStyle(Palette.textSecondary)

            // Two paragraphs with the list's own gap between them, so they read as two thoughts
            // in the panel's rhythm rather than as one paragraph that broke.
            VStack(spacing: Metrics.inset) {
                ForEach(Maker.identityParagraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Metrics.spacingWide + Metrics.spacingSmall)

            VStack(spacing: Metrics.inset) {
                ForEach(Maker.products, id: \.host) { product in
                    productRow(product)
                }
            }
            .padding(.top, Metrics.pane - Metrics.spacingSmall)
        }
        .frame(maxWidth: .infinity)
        .padding(Metrics.pane)
        .background(Palette.surface)
    }

    /// One product: its mark, then the name carrying the weight, the address carrying the link,
    /// and the sentence under both. The address is the link rather than the name, because a
    /// printed host says where the click goes before it is clicked, which is what makes three
    /// outbound links in an About window read as a reference list rather than as an
    /// advertisement. A row whose mark fails to load sets its text from the leading edge instead,
    /// because an empty box holding a column open for a missing image is the one way to make the
    /// absence louder than the mark.
    private func productRow(_ product: MakerProduct) -> some View {
        HStack(alignment: .top, spacing: Metrics.inset) {
            if let mark = Self.mark(named: product.logoResource) {
                Image(nsImage: mark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.productMark, height: Self.productMark)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                HStack(alignment: .firstTextBaseline) {
                    Text(product.name)
                        .font(Typo.captionEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: Metrics.spacing)
                    Link(product.host, destination: product.url)
                        .font(Typo.codeTiny)
                        .foregroundStyle(Palette.link)
                        .underline()
                }
                Text(product.summary)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The box every product mark occupies, so the three text columns start on one line. One box
    /// for all three, which is how the download email sets them, and not an optical correction
    /// per mark: Flare's bare glyph was tried two points smaller on the theory that art filling
    /// its file to the edge reads larger than a tile's inset art, and it read lighter instead,
    /// because an open glyph carries less mass than a solid tile, not more.
    private static let productMark: CGFloat = 22

    /// The email's own bitmaps, read out of the bundle; see `MakerProduct.logoResource`.
    private static func mark(named resource: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: The credit strip

    private var credit: some View {
        VStack(spacing: Metrics.spacingSmall) {
            // Underlined, which `Palette.link` is explicit is not decoration: it is what makes a
            // link findable without colour vision.
            Link(Maker.host, destination: Maker.url)
                .foregroundStyle(Palette.link)
                .underline()
                .font(Typo.codeSmall)

            if let copyright {
                Text(copyright)
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.inset + Metrics.spacingTight)
        .padding(.horizontal, Metrics.pane)
        // The chrome colour, which is what every strip of small print in this app stands on. Not
        // `surfaceSunken`: in dark that is two units off Abyss and the footer disappeared into the
        // bottom of the plinth with only the rule left to say there were two things.
        .background(Palette.sidebar)
    }

    /// The Spatie lockup, read out of the bundle rather than drawn here.
    ///
    /// One cut in both appearances, and deliberately not the pair `SpatieCredit` swaps between in
    /// the settings window. Two reasons, and they agree. This window is the site's footer, and the
    /// site signs every page with the blue badge, in the nav and in the footer both; and Spatie
    /// Blue `#197593` is the one colour the ramp calls safe on either ground, which is the whole
    /// reason `Palette.accentFill` is a single value.
    @ViewBuilder
    private var badge: some View {
        if let logo = Self.logo {
            // A PDF, so AppKit redraws the vector at whatever scale the display asks for and the
            // mark is sharp on Retina rather than a 2x bitmap enlarged.
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
                .frame(height: Self.badgeHeight)
                .accessibilityLabel("Spatie")
        } else {
            Text(verbatim: "Spatie")
                .foregroundStyle(Palette.textPrimary)
        }
    }

    private static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "SpatieLogo", withExtension: "pdf")
        else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// `NSHumanReadableCopyright`, which is where macOS reads it from too: the Finder's Get Info
    /// panel shows that key, and so did the panel this window replaces. One string, in the plist,
    /// rather than a second copy here that would drift from it. `Tools/build.sh` re-stamps the
    /// year when it assembles the bundle, so the value read here is current without anyone
    /// remembering January; see the comment there.
    private var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    // MARK: The site's plinth, which is artwork and not a window surface

    // Four values from `public/brand/PALETTE.md`, and they are deliberately not in `Palette`.
    // That is the window ramp: four surfaces and a rule, resolving differently in each appearance,
    // and CLAUDE.md is explicit that a fifth surface is how the app starts looking heavy again.
    // These are not surfaces. They are the colours the site is printed in, and they are the same
    // in both appearances for the same reason a record sleeve is the colour it was printed: the
    // mark was drawn for a deep ground and the wordmark set on one, so a plinth that turned white
    // in light mode would be showing a Bloom that exists nowhere else.
    //
    // Nothing below the rule does this. The makers section and the credit strip are `Palette`
    // throughout and follow the appearance like every other window in the app.

    /// Depth, the site's plinth gradient: Fathom `#123B57` at the top to Abyss `#061420` at the
    /// bottom. One of exactly two gradients the brand has, and the one that reads as looking down
    /// into water rather than as a gradient for its own sake.
    private static let depth = LinearGradient(
        colors: [
            Color(nsColor: NSColor(rgb: 0x123B57)),
            Color(nsColor: NSColor(rgb: 0x061420)),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Foam `#E9F7F4`, the ramp's near white. 16.9 to 1 on Abyss.
    private static let foam = Color(nsColor: NSColor(rgb: 0xE9F7F4))

    /// The site's `--mist-dim` `#8AA0AB`, which is what it sets a mono spec line in. 6.0 to 1 on
    /// Abyss, so the version stays readable rather than merely present.
    private static let mistDim = Color(nsColor: NSColor(rgb: 0x8AA0AB))
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
private struct PlinthWater: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PlinthWaterView { PlinthWaterView() }

    func updateNSView(_ view: PlinthWaterView, context: Context) {
        // Removed, not slowed: Reduce Motion means the water holds still, and the pools and the
        // ribbon stay, because the setting is about movement and held light is not moving. The
        // same rule `Motion`'s call sites follow.
        view.setMoving(!reduceMotion)
    }
}

private final class PlinthWaterView: NSView {
    /// The painting, larger than the view so no sway can show an edge. The site does the same
    /// with `inset: -35%`.
    private let canvas = CALayer()
    private let shallowPool = PlinthWaterView.pool(rgb: 0x9BE9DC, alpha: 0.14)
    private let currentPool = PlinthWaterView.pool(rgb: 0x2AA3B4, alpha: 0.16)
    private let ribbon = PlinthWaterView.ribbon(rgb: 0x7FE8D6, alpha: 0.07)
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
