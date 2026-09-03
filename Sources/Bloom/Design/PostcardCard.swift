import AppKit
import SwiftUI
import BloomCore

/// The postcard itself: an A6 card, written side up, with Spatie's address on it.
///
/// **The drawing and the information are the same object, and that is the whole idea.** The
/// alternative was an address set as four lines of type with a picture of a postcard next to it,
/// which is a diagram of the thing beside the thing. Here the address on screen IS the card, so
/// the one place somebody looks to read it is the one place the app has drawn what it is asking
/// for. Everything else on the card, the message rules, the stamp and the postmark, is what an
/// unwritten postcard actually has on its back, and none of it says anything the app is not
/// entitled to say: no city, no date, no franking value, nothing that would be a claim.
///
/// **Fixed brand colours in both appearances, for the reason `Brand` gives.** Foam paper, Fathom
/// ink, the plinth's own gradient in the stamp. A card that turned charcoal in dark appearance
/// would be a different object rather than the same object on a different ground, and the card has
/// to work on three grounds already: the window's plinth, the welcome window's reading band, and
/// the capture page. The stroke and the shadow are what let it sit on a white page without
/// dissolving into it.
///
/// **It moves once, when it appears, and then it is a picture.** See `PostcardArrival` for the
/// numbers and for why Reduce Motion gets no movement at all rather than a slower one. Nothing
/// here repeats and nothing here is driven by a timeline, because the window this sits in is one
/// somebody leaves open beside their work.
struct PostcardCard: View {
    /// How wide the card is drawn. Everything else on it is a fraction of this, so one drawing
    /// serves a window, a welcome step and a capture page without three sets of numbers.
    var width: CGFloat = PostcardCard.defaultWidth

    /// Whether the arrival is played at all.
    ///
    /// False on a screen somebody has already been on. A card landing again on the way back
    /// through a wizard is the same mistake `WelcomeGreeting.isFirstVisit` was written for: a
    /// return is not an arrival, and replaying an entrance on one turns a nice moment into a wait.
    var plays = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    /// The width the postcard window and the welcome step both draw it at.
    ///
    /// Chosen off the longest line of the address rather than off the window, and measured rather
    /// than estimated. "Kruikstraat 22, Box 12" set in the ten point monospaced rung comes to
    /// 136.0 points; the address column at this width is 149.3, which leaves thirteen points of
    /// slack. A narrower card, or a message side any wider than the 0.42 below, puts the street on
    /// two lines, and an address that wraps is an address somebody copies wrong by hand.
    static let defaultWidth: CGFloat = 340

    /// 148 by 105 millimetres, which is what an A6 postcard is, and therefore what this is.
    static let aspect: CGFloat = 148.0 / 105.0

    /// What a card of this width comes out at, so a caller can reserve the room before drawing it.
    static func height(for width: CGFloat) -> CGFloat { (width / aspect).rounded() }

    private var height: CGFloat { Self.height(for: width) }
    /// The margin the print keeps from the edge of the card.
    private var inset: CGFloat { (width * 0.05).rounded() }
    private var stampWidth: CGFloat { (width * 0.13).rounded() }
    private var stampHeight: CGFloat { (stampWidth * 1.18).rounded() }
    private var postmarkSize: CGFloat { (width * 0.085).rounded() }
    /// The corner of a guillotined card, which is small: a postcard is cut, not moulded.
    private var corner: CGFloat { 3 }

    /// The arrival, or nothing, which is what Reduce Motion and a return visit both get.
    private var settle: PostcardArrival.Settle? {
        guard plays else { return nil }
        return PostcardArrival.settle(reduceMotion: reduceMotion)
    }

    private var shadow: PostcardArrival.CardShadow {
        guard let settle, !landed else { return PostcardArrival.restShadow }
        return settle.startShadow
    }

    var body: some View {
        card
            .rotationEffect(.degrees(landed ? PostcardArrival.restAngle : startAngle))
            .scaleEffect(landed ? 1 : startScale)
            .offset(x: landed ? 0 : offsetX, y: landed ? 0 : offsetY)
            .opacity(landed ? 1 : startOpacity)
            // Animated along with everything else above, and it is the part that makes the rest
            // read as an object coming down rather than as a rectangle sliding. See the head of
            // `PostcardArrival`.
            .shadow(color: .black.opacity(shadow.opacity), radius: shadow.blur, y: shadow.drop)
            .onAppear(perform: land)
            // One element rather than seven. The rules, the stamp and the postmark say nothing
            // that is not already in this sentence, and four separately announced lines of an
            // address is four stops for something that is read as one thing.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("A postcard addressed to \(Postcard.addressLine)")
    }

    private var startAngle: Double { settle?.startAngle ?? PostcardArrival.restAngle }
    private var startScale: Double { settle?.startScale ?? 1 }
    private var startOpacity: Double { settle?.startOpacity ?? 1 }
    private var offsetX: Double { settle?.offsetX ?? 0 }
    private var offsetY: Double { settle?.offsetY ?? 0 }

    private func land() {
        guard !landed else { return }
        guard let settle else {
            landed = true
            return
        }
        // On the next runloop pass rather than inside `onAppear`, for the reason
        // `WelcomeGreeting` measured: a state change made while the view is still being installed
        // is applied without its animation, and the whole entrance is skipped.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: settle.seconds).delay(settle.delay)) {
                landed = true
            }
        }
    }

    // MARK: - The card

    private var card: some View {
        HStack(spacing: 0) {
            messageSide
            divider
            addressSide
        }
        .padding(inset)
        .frame(width: width, height: height)
        .background(paper)
        // So the postmark, which is drawn half off the stamp, cannot hang over the edge of the
        // card it is printed on.
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            // The cut edge. Half a point of ink, which is what keeps the card from dissolving
            // into a white page in light appearance without drawing a frame around it.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Brand.fathom.opacity(0.18), lineWidth: Metrics.outline)
        }
    }

    private var paper: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Brand.foam)
    }

    /// The left half, which is where a message goes: the printed guide rules and nothing else.
    ///
    /// Rules rather than anything resembling handwriting. A card with squiggles on it is a card
    /// with a fake message on it, and the point of this one is that it has not been written yet.
    private var messageSide: some View {
        VStack(spacing: 0) {
            ForEach(0..<Self.ruleCount, id: \.self) { _ in
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Brand.fathom.opacity(0.12))
                    .frame(height: Metrics.hairline)
            }
            Spacer(minLength: 0)
        }
        // A shade under half, and the shade is the address's. A postcard's two halves are usually
        // even, and even is exactly where "Kruikstraat 22, Box 12" stops fitting on one line.
        .frame(width: (width - inset * 2) * 0.42, alignment: .leading)
    }

    /// Six, which is what fits on an A6 card at a hand's line spacing.
    private static let ruleCount = 6

    /// The printed rule down the middle of the back of a postcard.
    private var divider: some View {
        Rectangle()
            .fill(Brand.fathom.opacity(0.22))
            .frame(width: Metrics.hairline)
            .padding(.vertical, height * 0.03)
            .padding(.horizontal, inset * 0.8)
    }

    /// The right half: the stamp and its postmark at the top, the address at the foot.
    private var addressSide: some View {
        VStack(alignment: .leading, spacing: 0) {
            franking
            Spacer(minLength: Metrics.spacing)
            address
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The stamp with the postmark half over it, which is where a cancellation lands.
    private var franking: some View {
        ZStack(alignment: .topTrailing) {
            postmark
                .offset(x: -stampWidth * 0.66, y: stampHeight * 0.34)
            stamp
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var stamp: some View {
        Rectangle()
            .fill(Brand.depth)
            .overlay {
                // The app's own mark, read out of the running bundle rather than shipped a second
                // time, which is what `AboutView` does with it and for the same reason: this
                // cannot show a Bloom the app has stopped using.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .padding(stampWidth * 0.14)
            }
            .overlay {
                // The perforation, drawn as a dotted fringe in the paper's own colour rather than
                // as forty small circles cut out of the edge. At two and a half points of dash on
                // a forty four point stamp it reads as the torn edge it is standing in for, and it
                // costs one stroke instead of a path built per stamp.
                Rectangle()
                    .strokeBorder(
                        Brand.foam,
                        style: StrokeStyle(lineWidth: 2.5, dash: [2, 2])
                    )
            }
            .frame(width: stampWidth, height: stampHeight)
    }

    /// Two rings and a bar, tilted, which is a cancellation with nothing written in it.
    ///
    /// Deliberately empty. A postmark carries a place and a date, and both would be a fact this
    /// app has invented: the card on screen has not been posted from anywhere on any day. What is
    /// left is the shape, which is what says the card has travelled.
    private var postmark: some View {
        ZStack {
            Circle().strokeBorder(Brand.fathom.opacity(0.42), lineWidth: 1.2)
            Circle().strokeBorder(Brand.fathom.opacity(0.28), lineWidth: 0.8).padding(3)
            Capsule()
                .fill(Brand.fathom.opacity(0.30))
                .frame(width: postmarkSize * 0.44, height: 1.2)
        }
        .frame(width: postmarkSize, height: postmarkSize)
        .rotationEffect(.degrees(-11))
    }

    private var address: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            ForEach(Array(Postcard.addressLines.enumerated()), id: \.offset) { position, line in
                Text(line)
                    .font(Typo.codeTiny)
                    .foregroundStyle(Brand.fathom)
                    // One line, always. The width is chosen so the longest of them fits at this
                    // rung; the floor is there for a machine whose system text size has moved the
                    // rung out from under that measurement, where a shrunk line is a better answer
                    // than a wrapped or a clipped one.
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    // The country stands slightly apart, which is how an address for another
                    // country is written and what makes these four lines read as an address
                    // rather than as a list.
                    .padding(.top, position == Postcard.addressLines.count - 1 ? Metrics.spacingSmall : 0)
            }
        }
    }
}
