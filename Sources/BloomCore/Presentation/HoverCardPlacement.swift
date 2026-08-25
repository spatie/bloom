import CoreGraphics

/// Where the card that opens beside a sidebar row is put, in screen coordinates.
///
/// It is a floating panel rather than something drawn inside the window, because the card has to
/// stand to the RIGHT of a 260 point sidebar and the sidebar is an `NSSplitView` subview, which
/// clips. So the position cannot be a layout, it has to be a rectangle worked out by hand, and a
/// rectangle worked out inside a view is a rectangle nothing can check. Three of the four cases
/// below only happen at the edges of a screen, which is exactly where a hand-checked card is
/// never looked at.
///
/// Everything here is AppKit's coordinate space: y increases upwards and `maxY` is the top edge.
/// The anchor is the row's own rectangle on screen and the card is placed beside it, not under
/// the pointer: a card that follows the pointer inside a 32 point row wobbles as the hand
/// settles, and the thing being described is the row.
public enum HoverCardPlacement {
    /// The gap between the row and the card.
    ///
    /// Enough that the card reads as a separate surface floating over the centre pane rather than
    /// as a panel welded to the sidebar's edge, and small enough that the eye carries the row's
    /// line across to it. The sidebar already ends in a hairline rule, so a card flush against it
    /// would put a border and a rule half a point apart, which is the smear
    /// `Metrics.headerButton` was measured to avoid one rung down.
    public static let gap: CGFloat = 8

    /// How close to the top or bottom of the screen the card may come before it is pushed back
    /// in. The same margin AppKit keeps a menu off a screen edge by.
    public static let screenMargin: CGFloat = 8

    /// The card's rectangle for a row at `anchor`, on a screen whose usable area is `visible`.
    ///
    /// Three decisions, in this order:
    ///
    /// 1. **Right of the row, unless there is no room.** The sidebar is the leftmost column of the
    ///    window, so the right is where the space is and where the reader's eye already travels.
    ///    A window pushed against the right edge of a screen, which is where a wide window with a
    ///    collapsed inspector sits, has none, and there the card flips to the left of the row
    ///    rather than hanging off the screen. Flipping is preferred to squeezing: a card narrowed
    ///    to fit is a card that truncates the title, which is the one thing it exists to show.
    /// 2. **Top aligned with the row.** The row is the subject, and lining the card's first line
    ///    up with it is what says so. Centring it on the row was tried on paper and reads as the
    ///    card belonging to the two rows either side as much as to this one.
    /// 3. **Clamped into the screen, vertically then horizontally.** A card opened on the last row
    ///    of a full sidebar would otherwise run off the bottom, which is where the age and the
    ///    pull request number are.
    ///
    /// Nothing here consults the window. The card may overlap the transcript, and should: it is a
    /// card that opens over what you are reading and closes again, exactly as a menu does.
    public static func frame(
        anchor: CGRect,
        size: CGSize,
        visible: CGRect
    ) -> CGRect {
        var origin = CGPoint(
            x: anchor.maxX + gap,
            // `maxY` on both sides: the card's top edge on the row's top edge.
            y: anchor.maxY - size.height
        )

        // The flip. Measured against the whole card, so a card that would be cut off by one point
        // moves rather than being clipped by one point.
        if origin.x + size.width > visible.maxX - screenMargin {
            let flipped = anchor.minX - gap - size.width
            // Only when the other side genuinely has room. On a screen too narrow for the card
            // beside the window at all, flipping trades one overhang for another, and the clamp
            // below is a better answer than a card that has jumped to the wrong side as well.
            if flipped >= visible.minX + screenMargin { origin.x = flipped }
        }

        origin.x = min(origin.x, visible.maxX - screenMargin - size.width)
        origin.x = max(origin.x, visible.minX + screenMargin)

        // Lifted off the bottom first and pushed down off the top second, so that on a screen too
        // short for the card at all it is the TOP edge that survives. The title and the branch
        // are drawn there and the age is at the foot, which is the one line worth losing.
        origin.y = max(origin.y, visible.minY + screenMargin)
        origin.y = min(origin.y, visible.maxY - screenMargin - size.height)

        return CGRect(origin: origin, size: size)
    }
}
