import AppKit
import BloomCore
import SwiftUI

/// A stamp on its own, for the About panel, which says Bloom is postcardware in one sentence and
/// must not draw a second postcard three inches from the first.
///
/// **The smallest part of the object rather than the object.** `PostcardCard` is the card, and it
/// belongs on the two screens that are about sending one: the postcard window and the welcome
/// step. The About panel is a page of credits with one line about postcardware on it, so what it
/// carries is the mark that says "post" and nothing else. A card here would be the same thing said
/// twice and would take the panel over.
///
/// The drawing is deliberately the card's own stamp, down to the dotted fringe standing in for the
/// perforation, so the two never drift into being two different stamps. What differs is only the
/// arrival: a card is set down and a stamp is pressed on. See `PostcardArrival.press`.
struct PostcardStamp: View {
    /// False on any appearance that should show the stamp already pressed on: a panel being
    /// redrawn rather than opened. Reduce Motion is asked separately and answers for itself.
    var plays = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    /// The stamp is a little larger than the one on the card, because here it is the only thing
    /// carrying the idea rather than one mark among rules, an address and a postmark.
    private static let width: CGFloat = 34
    private static let height: CGFloat = 40

    /// Nil when nothing should move, which is Reduce Motion or a redraw. A caller cannot honour
    /// half of a press it was never handed. See `PostcardArrival.press`.
    private var press: PostcardArrival.Press? {
        guard plays else { return nil }
        return PostcardArrival.press(reduceMotion: reduceMotion)
    }

    var body: some View {
        stamp
            .scaleEffect(pressed ? 1 : (press?.startScale ?? 1))
            .opacity(pressed ? 1 : (press?.startOpacity ?? 1))
            .accessibilityHidden(true)
            .onAppear(perform: settle)
    }

    /// Drawn at rest on the first frame when nothing is going to move, so a reader with Reduce
    /// Motion on never sees the state the animation would have started from.
    private func settle() {
        guard let press else {
            pressed = true
            return
        }
        withAnimation(.easeOut(duration: press.seconds).delay(press.delay)) {
            pressed = true
        }
    }

    /// The card's stamp, at this screen's size. Kept in step with `PostcardCard.stamp` by being
    /// the same three layers in the same order: the ink, the app's own mark, the fringe.
    private var stamp: some View {
        Rectangle()
            .fill(Brand.depth)
            .overlay {
                // Read out of the running bundle rather than shipped a second time, which is what
                // `AboutView` and the card both do: this cannot show a Bloom the app has stopped
                // using.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .padding(Self.width * 0.14)
            }
            .overlay {
                Rectangle()
                    .strokeBorder(
                        Brand.foam,
                        style: StrokeStyle(lineWidth: 2, dash: [2, 2])
                    )
            }
            .frame(width: Self.width, height: Self.height)
    }
}
