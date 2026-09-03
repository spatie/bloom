import SwiftUI
import BloomCore

/// The two places the postcard is drawn, side by side, at the widths they are drawn at.
///
/// It exists for the reason `WelcomeOffersGallery` exists. Both of these are behind a menu item or
/// four presses of a wizard, so the only way to look at either used to be to open the real window
/// on somebody's real desktop, and the owner is working at that desktop. A page rendered offscreen
/// costs nobody their focus.
///
/// Two columns rather than one, because the question a new screen raises is not what it says on
/// its own, it is whether it matches the screen beside it. The card is one drawing on two grounds:
/// the window stands it on the plinth, where it is dark artwork in both appearances, and the
/// welcome step stands it on the reading surface, which is white in light and near black in dark.
/// That is exactly where a card drawn in fixed brand colours can go wrong, and this page is where
/// it can be seen not to.
///
/// Both are the real views with the real strings, so this page cannot say the copy is one thing
/// while the window says another. Neither plays its arrival: a render is photographed a moment
/// after it is built, and a card caught halfway down would be a picture of an animation. The
/// movement itself is `PostcardArrival`, which is numbers in the core with a test over them.
///
///     Bloom --snapshot-gallery /tmp/shots --gallery postcard
struct PostcardGallery: View {
    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            column("Help, Send Us a Postcard") {
                PostcardView(plays: false)
            }

            column("The welcome window's last step") {
                // The reading band alone, bounded by the two hairlines it sits between, which is
                // how `WelcomeOffersGallery` draws its two. The plinth and the footer above and
                // below it are `WelcomeView`'s, are private to it, and are identical on every step
                // of that window.
                VStack(spacing: 0) {
                    Rectangle().fill(Palette.border).frame(height: Metrics.hairline)
                    WelcomePostcard(isFirstVisit: false)
                    Rectangle().fill(Palette.border).frame(height: Metrics.hairline)
                }
                .frame(width: Self.welcomeWidth)
                .background(Palette.surface)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func column<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)

            content()
        }
    }

    /// `WelcomeView.width`, which is private to it. Repeated rather than published, for the reason
    /// `WelcomeOffersGallery` gives: widening a view's constants so a capture page can read them is
    /// the wrong trade, and a page whose caption is stale is a worse page rather than a bug.
    private static let welcomeWidth: CGFloat = 520
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    static let postcard = Gallery(
        name: "postcard",
        title: "The postcard, in the window and in the welcome sequence",
        size: CGSize(width: 1_112, height: 700),
        needsFocus: false,
        view: { _ in AnyView(PostcardGallery()) }
    )
}
