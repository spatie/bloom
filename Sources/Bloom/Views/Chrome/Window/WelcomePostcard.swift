import SwiftUI
import BloomCore

/// The welcome window's last screen: what Bloom asks for, which is a postcard.
///
/// **It is the only screen in the sequence that asks for nothing.** The checks want a look at the
/// machine, the command line step wants a line run in a terminal, the prompt step wants something
/// typed into a form. This one hands over an address and stops. A sequence that ended on a form
/// would end with the reader still owing something; this ends on the one screen anybody might
/// remember a week later, and that is the whole argument for it being last. See `OnboardingStep`,
/// where the position is written down beside the case.
///
/// Nothing here has to be done and nothing here can be got wrong: the footer's button says "Start
/// using Bloom" and does exactly that, whether the address was copied or not.
///
/// One paragraph rather than the two the postcard window sets. The card is a card's worth of
/// height and the screens before this one are not tall, so the sentence about the wall is left to
/// the link under it. See `Postcard.lead`.
struct WelcomePostcard: View {
    /// False when somebody has walked back to this screen. A card landing twice is a return being
    /// dressed up as an arrival, which is the same judgement `WelcomeGreeting` makes about its own
    /// entrance.
    let isFirstVisit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.pane - Metrics.spacingSmall) {
            // The same two rungs the three screens before this one open on, so all four read as
            // pages of one window: a serif line, then the sentence explaining it at the rung this
            // window sets prose at.
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Text(Postcard.headline)
                    .font(Typo.displayHeading)
                    .foregroundStyle(Palette.textPrimary)

                Text(Postcard.lead)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Centred, which is the one thing on this screen that is. Everything else in the
            // welcome window is a left aligned column because it is text and controls; this is an
            // object, and an object pushed against the leading margin reads as a picture that was
            // laid out rather than as a card lying on the page.
            PostcardCard(plays: isFirstVisit)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: Metrics.inset) {
                PostcardOffer()
                PostcardWallLink()

                // Where to find this again, in the line the two screens before this one both use
                // to say the same thing about a settings pane and a menu item. Not an ask: it is
                // the one fact somebody walking past this screen at speed will want later, which
                // is a week from now when they are standing in a post office.
                Text("The Help menu has the address again, under Send Us a Postcard.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
