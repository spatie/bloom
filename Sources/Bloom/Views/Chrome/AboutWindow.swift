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
/// site's own furniture: the Depth plinth, the mark on it, the name set in a serif, a mono spec
/// line under it, and the footer's credit strip below the rule. `public/brand/PALETTE.md` and
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

/// What that window draws. Every number and every sentence in it lives here.
private struct AboutView: View {
    /// Narrow, and the reason is the credit line: "Made by Spatie in Antwerp, Belgium" set in mono
    /// at eleven points is the widest thing in the window, and the window is the width that holds
    /// it on one line with the site's gutter either side. Everything above it is centred and would
    /// be happy at any width.
    private static let width: CGFloat = 360

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
            Rectangle()
                .fill(Palette.border)
                .frame(height: Metrics.hairline)
            credit
        }
        .frame(width: Self.width)
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
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 38)
        .padding(.bottom, 26)
        .background(Self.depth)
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

    // MARK: The credit strip

    private var credit: some View {
        VStack(spacing: Metrics.spacingWide) {
            // The site's footer, in the site's words and the site's order. The mark rather than
            // the name, because that is how Spatie signs the page it made.
            HStack(spacing: Metrics.spacing) {
                Text("Made by")
                badge
                Text("in Antwerp, Belgium")
            }
            .foregroundStyle(Palette.textSecondary)

            // Underlined, which `Palette.link` is explicit is not decoration: it is what makes a
            // link findable without colour vision.
            Link(Self.host, destination: Self.spatie)
                .foregroundStyle(Palette.link)
                .underline()

            if let copyright {
                Text(copyright)
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.top, Metrics.spacingSmall)
            }
        }
        // Mono for the whole strip, which is what `.footer` on the site is set in. A credit line,
        // an address and a copyright are all things read off the thing above them rather than
        // prose, and setting the three in one face is what makes them read as one footer instead
        // of as three separate remarks.
        .font(Typo.codeSmall)
        .frame(maxWidth: .infinity)
        .padding(Metrics.pane)
        // The chrome colour, which is what every strip of small print in this app stands on. Not
        // `surfaceSunken`: in dark that is two units off Abyss and the footer disappeared into the
        // bottom of the plinth with only the rule left to say there were two things.
        .background(Palette.sidebar)
    }

    /// The Spatie lockup, read out of the bundle rather than drawn here.
    ///
    /// One cut in both appearances, and deliberately not the pair `SpatieCredit` swaps between in
    /// the settings window. Two reasons, and they agree. This window is the site's footer, and the
    /// site signs every page with the blue badge on a dark ground, in the nav and in the footer
    /// both; and Spatie Blue `#197593` is the one colour the ramp calls safe on either ground,
    /// which is the whole reason `Palette.accentFill` is a single value. The white cut on the dark
    /// strip was tried and it is the brightest thing in the window, which is not what a signature
    /// at the foot of an About box should be.
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
    /// rather than a second copy here that would drift from it.
    private var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    // MARK: The words and the addresses

    /// Shown without a scheme, because that is how the site prints it: the ghost button at the
    /// foot of the makers section says `spatie.be` and points at `https://spatie.be`, which is
    /// `config('bloom.maker_url')` there.
    private static let host = "spatie.be"

    /// Force unwrapped, as the other two spatie.be links in this app are. It is a literal with a
    /// scheme and a host and nothing in it that can fail to parse, so a fallback here would be an
    /// unreachable branch dressed up as a safety net.
    private static let spatie = URL(string: "https://\(host)")!

    // MARK: The site's plinth, which is artwork and not a window surface

    // Four values from `public/brand/PALETTE.md`, and they are deliberately not in `Palette`.
    // That is the window ramp: four surfaces and a rule, resolving differently in each appearance,
    // and CLAUDE.md is explicit that a fifth surface is how the app starts looking heavy again.
    // These are not surfaces. They are the colours the site is printed in, and they are the same
    // in both appearances for the same reason a record sleeve is the colour it was printed: the
    // mark was drawn for a deep ground and the wordmark set on one, so a plinth that turned white
    // in light mode would be showing a Bloom that exists nowhere else.
    //
    // Nothing below the rule does this. The credit strip is `Palette` throughout and follows the
    // appearance like every other window in the app.

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
