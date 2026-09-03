import AppKit
import SwiftUI
import BloomCore

/// The window behind Help's Send Us a Postcard.
///
/// It is the About window's near relative and is built the same way, deliberately: the same
/// plinth, the same rule under it, the same reading ground beneath that, and the same fixed width
/// column that is sized by its content rather than by a number typed into a window frame. Two
/// windows that say who made this and what they ask for should be recognisably the same pair of
/// windows, and the one thing that separates them is what stands on the plinth. In About it is the
/// app's mark, which is the app introducing itself. Here it is the postcard, which is the thing
/// being asked for, drawn at the size it is and carrying the address that is the whole point of
/// the window.
///
/// **The card is the address.** There is no second copy of it set as four lines of type below,
/// because two addresses on one screen is two things to get wrong, and the copy button under it
/// puts the same four lines on the pasteboard. See `PostcardCard`.
///
/// **Two things move in here and only one of them is new.** The card lands once and then rests;
/// `PostcardArrival` is the whole of it and it is over inside a second. The water in the plinth
/// behind it does what it does in the About window and the welcome window, which is drift, and it
/// is kept rather than dropped because a plinth without it is a flat gradient and the three
/// windows would stop being one family. Its cost is measured rather than assumed and its frame
/// rate is capped for exactly this case, a window left open beside somebody's work: see the head
/// of `BrandWater`, and note that it stops entirely under Reduce Motion.
///
/// One instance, kept here, and `isReleasedWhenClosed` off, for the reason `AboutWindow`
/// documents: it defaults to true for a window built in code, so without that line the second
/// visit messages a window the first close deallocated.
@MainActor
enum PostcardWindow {
    private static var window: NSWindow?

    /// Opens it, or brings the one that is already open forward.
    ///
    /// Not re-centred on a second visit, and the card is not re-thrown either: the arrival plays
    /// when the view appears, and a window ordered forward has not appeared again. Somebody who
    /// left this open beside their work and came back to copy the address gets the address, not
    /// the animation a second time.
    static func show() {
        let existing = window ?? make()
        window = existing
        existing.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let host = NSHostingView(rootView: PostcardView())
        // Asked for rather than written down, exactly as `AboutWindow` does it, so the numbers in
        // `PostcardView` are the only ones and a change to its padding cannot leave the window an
        // inch too tall.
        let size = host.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // No `.resizable` and no `.miniaturizable`, for the reason the About window gives:
            // there is nothing in here to resize and nothing to come back to.
            // `.fullSizeContentView` is what lets the plinth run up behind the title bar, the
            // alternative being a strip of flat window background above the gradient.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Set even though it is hidden: it is what the Window menu and the accessibility hierarchy
        // call this window. The Help menu's own wording, minus the ellipsis a menu row carries to
        // say that a window is coming, so the two surfaces cannot teach different names.
        window.title = "Send Us a Postcard"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The title bar carries no title and is transparent, so there is no strip left to drag the
        // window by. The plinth becomes that strip instead.
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = host
        window.setContentSize(size)
        window.center()
        // Escape as well as Cmd+W. This is a window somebody reads, copies one thing out of, and
        // puts away, and there is nothing in it either key could have meant instead. Unlike the
        // welcome window, which is `.utility` because a terminal can appear inside it and Escape
        // there belongs to whatever is running. See `WindowRoles`.
        WindowRoles.mark(window, as: .reading)
        return window
    }
}

/// What that window draws.
///
/// Every number in it lives here; every sentence and the address itself live in `Postcard`, for
/// the reason `AboutView` keeps its own copy in `Maker`: a string typed into this file is a string
/// nothing in `Tests/BloomCoreTests` can hold still, and an address is the one string in this app
/// where being wrong is expensive to everybody who acts on it.
///
/// Internal rather than private, unlike `AboutView`, for one reason: `PostcardGallery` draws it.
/// This window cannot be looked at from a capture run any other way, and a page rendered offscreen
/// costs nobody their focus, which is the argument `WelcomeOffersGallery` opens with.
struct PostcardView: View {
    /// Whether the card plays its arrival.
    ///
    /// False on the capture page, where the render is photographed a moment after it is built and
    /// a card caught halfway down is a picture of an animation rather than a picture of the
    /// window. Nothing else ever passes it.
    var plays = true

    /// The About window's width, and the same argument for it: wide enough for the prose to set
    /// without an orphaned line, and no wider, because this is a column of one card and two
    /// paragraphs and surplus width reads as a dialog that forgot its content. It also has to
    /// clear the card, which is 340 and turns two and a half degrees when it lands, so the widest
    /// the drawing ever measures is about 350.
    private static let width: CGFloat = 460

    /// The brand band's own numbers, off the spacing scale on purpose and for the reason
    /// `AboutView` and `WelcomeView` both write down: this is a fixed size window's header laid
    /// out against a title bar rather than against a row of controls.
    ///
    /// Top and bottom are not equal. The card lands two and a half degrees off square, so its
    /// lower leading corner reaches further down than its upper one reaches up, and equal padding
    /// left it visibly closer to the rule than to the title bar.
    private static let plinthTop: CGFloat = 34
    private static let plinthBottom: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            plinth
            rule
            reading
        }
        .frame(width: Self.width)
    }

    private var rule: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: Metrics.hairline)
    }

    // MARK: The plinth

    /// The card, on the water, where the About window puts the app's mark.
    ///
    /// `.clipped()` sits between the content and the background on purpose. It holds the card's
    /// travelling shadow inside the band, which at the top of the fall reaches thirty points
    /// further than the resting one and would otherwise spill over the rule and onto the reading
    /// ground for half a second. The background is added after it, so the water still bleeds up
    /// under the title bar the way `.fullSizeContentView` exists to let it.
    private var plinth: some View {
        PostcardCard(plays: plays)
            .padding(.top, Self.plinthTop)
            .padding(.bottom, Self.plinthBottom)
            .frame(maxWidth: .infinity)
            .clipped()
            .background {
                ZStack {
                    Brand.depth
                    BrandWater()
                }
                .clipped()
                .ignoresSafeArea(edges: .top)
            }
    }

    // MARK: The reading ground

    /// The headline, the two paragraphs, and the two controls, in the bands and at the rungs the
    /// welcome window's screens already set: a serif line, the sentences under it at reading size,
    /// then whatever the screen offers.
    private var reading: some View {
        VStack(alignment: .leading, spacing: Metrics.pane - Metrics.spacingSmall) {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Text(Postcard.headline)
                    .font(Typo.displayHeading)
                    .foregroundStyle(Palette.textPrimary)

                // The gap between the two is the list's own, so they read as two thoughts in the
                // window's rhythm rather than as one paragraph that broke. Same as `AboutView`.
                VStack(alignment: .leading, spacing: Metrics.inset) {
                    ForEach(Postcard.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(Typo.body)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: Metrics.inset) {
                PostcardOffer()
                PostcardWallLink()
            }
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
    }
}
