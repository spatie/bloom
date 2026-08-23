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
                .foregroundStyle(Brand.foam)
                .padding(.top, Metrics.spacingWide)

            // The site's `.hero__spec`: mono, small, dimmed, with a middle dot between the parts.
            Text(versionLine)
                .font(Typo.codeSmall)
                .foregroundStyle(Brand.mistDim)
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
                Brand.depth
                BrandWater()
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
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Self.productMarkRadius, style: .continuous))
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

    /// The corner the three marks share, and the reason they sit on white.
    ///
    /// THE GROUND. Mailcoach's mark is not a drawing on a tile, it is a tile with the drawing cut
    /// out of it: the glyph is a hole in the navy, alpha zero, so whatever is behind the mark is
    /// what the glyph shows. On the email's white page that reads as a white glyph. In dark
    /// appearance the panel behind it is `Palette.surface`, which is 0A1A25, and 142D6F against
    /// 0A1A25 is a contrast ratio of 1.4 to 1 for both the tile against the panel and the glyph
    /// against the tile, so the whole mark collapsed into one navy smudge. It drew perfectly and
    /// said nothing, which is why checking that three images appeared is not the same test as
    /// reading them. The white behind every mark is the ground that mark was cut for.
    ///
    /// WHY ALL THREE AND NOT ONLY THE ONE THAT BROKE. Painting the hole white in the bitmap
    /// would have fixed Mailcoach alone and left the row as it was: a tile, a tile with a
    /// different corner, and a bare glyph, which is three products presented three ways. On one
    /// white ground clipped to one corner the row is a set. Flare's glyph is the only one the
    /// white is visible behind, and it is the ground Flare's own app icon is drawn on, not a
    /// background invented for it here. In light appearance the panel is white already, so this
    /// shows as nothing at all and only the shared corner is doing work.
    ///
    /// THE RADIUS. 6 points at 22, which is the corner Mailcoach's own tile already carries.
    /// Clipping takes material away and cannot put it back, so a smaller number would have left
    /// Mailcoach round and squared There There off against it, and a larger one would have cut a
    /// white sliver out of Mailcoach's corners. Matching the roundest of the three is the only
    /// value that lands both tiles on the same silhouette.
    private static let productMarkRadius: CGFloat = 6

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
}
