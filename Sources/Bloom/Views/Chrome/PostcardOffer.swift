import BloomCore
import SwiftUI

/// The two controls that go under a postcard: the address onto the pasteboard, and the way through
/// to the wall it ends up on.
///
/// Two places draw it, the postcard window and the last step of the welcome sequence, so it is one
/// file for the reason `CommandLineOffer` is one file: what must not become two things is the
/// wording, and a button that says one thing in a window and another in a wizard teaches two names
/// for one address.
///
/// **The copy button is the whole reason this is a control rather than a line of type.** An
/// address read off a screen is an address about to be typed into a label, an envelope template or
/// a note, and every character of "Kruikstraat 22, Box 12" is one somebody can get wrong. What
/// lands on the pasteboard is `Postcard.address`, which is the four lines with their line breaks
/// intact rather than the one line form, because a line broken address is what an address is for.
///
/// The flash follows the pattern the other three copy buttons in this app agreed on: the label
/// becomes "Copied" for `Clipboard.flashDuration` and the button is dead while it says so, which
/// is what keeps a second press from restarting a timer under the first one's label.
struct PostcardOffer: View {
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            // The address is on the card above, in the app's mono face, so this is not a second
            // copy of it. It is the sentence that says what the button will put on the pasteboard,
            // which is the one thing a copy button cannot show.
            Text("The address goes on the pasteboard as four lines, ready to write onto a card.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Metrics.spacing)

            Button(didCopy ? "Copied" : "Copy address") { copy() }
                .disabled(didCopy)
        }
    }

    /// The pasteboard work, out of the `body` and out of the button's own closure body, through
    /// the one place in this app that clears the pasteboard before writing to it.
    private func copy() {
        Clipboard.copy(Postcard.address)
        didCopy = true
        Task {
            try? await Task.sleep(for: Clipboard.flashDuration)
            didCopy = false
        }
    }
}

/// The line under it: where the cards go, and the way there.
///
/// Its own view rather than a third element of the row above, because that row is a sentence and a
/// button and this is neither. The host carries the link and the phrase labels it, which is the
/// arrangement `AboutView` uses for its three products and for the same reason: a printed address
/// says where a click goes before it is clicked, and that is what keeps an outbound link in a
/// window like this reading as a reference rather than as an advertisement.
struct PostcardWallLink: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
            Text(Postcard.wallTitle)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)

            Link(Postcard.wallHost, destination: Postcard.wall)
                .font(Typo.codeTiny)
                .foregroundStyle(Palette.link)
                .underline()
        }
    }
}
