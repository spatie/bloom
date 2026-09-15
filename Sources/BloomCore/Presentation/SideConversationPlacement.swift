import CoreGraphics

/// Where the side conversation card is drawn inside its chat pane, and where its tail meets it.
///
/// The card is dressed as a popover hanging off the side conversation button in the composer
/// footer, but it is an overlay in the pane rather than a real popover (`ChatPaneView` says why),
/// so nothing in the system positions it or points its arrow. That is a rectangle worked out by
/// hand, and the cases where it goes wrong are a pane dragged narrow or short, which is exactly
/// where nobody checks one by eye. So it is worked out here, where the suite can.
///
/// **The tail always reaches the button, and the card covers the top of the main composer.** It
/// did not start that way. The first version stopped the tip twelve points above the composer
/// whenever 360 points of transcript were showing, so the main composer stayed uncovered, and only
/// dropped to the button in a short pane. Set beside the quick prompts popover one button to the
/// left, which is a real `.popover(arrowEdge: .top)`, that card read as detached: a long empty
/// stretch between its tail and the button it claimed to belong to, where the system's popover
/// sits on its button and lays its body over the composer's text line. The system's version is
/// the one that reads as native, and the side conversation has a composer of its own, so covering
/// the main one while the card is open costs nothing that closing the card does not give back.
///
/// SwiftUI's coordinate space throughout: the origin is the pane's top leading corner and y grows
/// downwards. `frame` includes the tail, so a view can be sized and placed with it directly.
public struct SideConversationPlacement: Equatable, Sendable {
    /// The card, tail included, in the pane's space.
    public var frame: CGRect
    /// Where the tail's tip is, measured from the card's leading edge. Nil when there is no button
    /// to point at, and then the card has no tail and `frame` is the body alone.
    public var tailX: CGFloat?

    /// The largest the card gets. It shrinks to fit a smaller pane rather than overflowing it.
    public static let maximumSize = CGSize(width: 560, height: 520)
    /// What the card keeps from the pane's edges.
    public static let margin: CGFloat = 12
    /// The tail, which is about the size of the arrow a system popover on macOS 26 draws.
    public static let tailSize = CGSize(width: 20, height: 9)
    /// Between the tail's tip and the top of the button's frame: none, which is what `NSPopover`
    /// leaves. A SwiftUI `.popover` hands AppKit the bounds of the view it is attached to as the
    /// positioning rect, and the arrow's tip is put on that rect's edge. The quick prompts popover
    /// is attached to a `ComposerControlLabel`, and so is this button, so both anchors are the
    /// same 28 point box with the glyph centred in it. The few points the eye sees between the
    /// quick prompts arrow and its glyph are the inside of that box, and a gap of nought against
    /// the same box reproduces them rather than adding a second gap on top.
    static let buttonGap: CGFloat = 0

    public init(frame: CGRect, tailX: CGFloat?) {
        self.frame = frame
        self.tailX = tailX
    }

    /// - Parameters:
    ///   - pane: The chat pane's size.
    ///   - anchor: The side conversation button's frame in the pane's space, or nil when the
    ///     footer has not reported it.
    ///   - cornerRadius: The card's corner radius, which the tail is kept clear of.
    public init(pane: CGSize, anchor: CGRect?, cornerRadius: CGFloat) {
        let width = max(0, min(Self.maximumSize.width, pane.width - 2 * Self.margin))

        guard let anchor else {
            // The main composer always shows the button, so this is the frame before its anchor
            // preference has arrived rather than a place the card lives. Bottom trailing, where
            // the button's end of the footer is, and over the composer as the anchored card is,
            // so the card does not jump upwards past the composer when the anchor lands.
            let height = max(0, min(Self.maximumSize.height, pane.height - 2 * Self.margin))
            self.init(
                frame: CGRect(
                    x: pane.width - Self.margin - width,
                    y: pane.height - Self.margin - height,
                    width: width,
                    height: height
                ),
                tailX: nil
            )
            return
        }

        // The tip sits on the button whatever the pane's height, and a pane too short for the
        // whole card takes height off the card's top instead of lifting the tail off the button.
        let tip = anchor.minY - Self.buttonGap
        let bodyBottom = tip - Self.tailSize.height
        let bodyHeight = max(0, min(Self.maximumSize.height, bodyBottom - Self.margin))

        // Centred on the button, then pulled back inside the pane. The button is at the trailing
        // end of a footer, so on any pane narrower than about twice the card this clamp is what
        // decides where the card goes, and the tail below is what keeps it pointing at the button.
        let latest = max(Self.margin, pane.width - Self.margin - width)
        let x = min(max(anchor.midX - width / 2, Self.margin), latest)

        // The tail follows the button across the card, but stops short of the rounded corners: a
        // tail that starts inside a corner's curve leaves a notch in the outline.
        let inset = cornerRadius + Self.tailSize.width / 2
        let tailX = inset <= width - inset
            ? min(max(anchor.midX - x, inset), width - inset)
            : width / 2

        self.init(
            frame: CGRect(
                x: x,
                y: bodyBottom - bodyHeight,
                width: width,
                height: bodyHeight + Self.tailSize.height
            ),
            tailX: tailX
        )
    }
}
