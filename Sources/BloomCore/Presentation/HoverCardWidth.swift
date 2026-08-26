import CoreGraphics

/// How wide a hover card may be, and how wide it should be for what is on it.
///
/// The card beside a sidebar row was 320 points flat. A workspace on
/// `freekmurze/review-support-question` drew it as `…eekmurze/review-support-question`, which is a
/// card truncating the one line it was opened to un-truncate. So the width follows the content
/// now, between the two bounds below.
///
/// Here rather than in the view because both bounds are judgements with a measurement behind
/// them, and because four cards in this app share them.
public enum HoverCardWidth {
    /// The floor, and the width the card used to be at all times.
    ///
    /// It keeps the reason it was picked for: wider than the 260 point sidebar, because a card as
    /// wide as the pane it opens out of reads as the pane repeated rather than as the pane
    /// explained, and wide enough for a two line workspace name at reading size. That reason
    /// survives the change from a fixed width to a floor, and as a floor it answers a case a fixed
    /// width never had to. A workspace called `x` on a branch called `x` is still a card.
    public static let minimum: CGFloat = 320

    /// The ceiling, which is the box every card that floats over the centre pane already takes.
    ///
    /// Three of them arrived at this number independently before it had a name: `ToolRowCard`,
    /// `AttachmentCard` and `SlashCommandCard`, each written against the last. The reason recorded
    /// on the first is the reason here. The card borrows the space it is drawn over rather than
    /// owning it, and 520 is wide enough for a shell command with a couple of flags on one line.
    ///
    /// Checked against the line that forced this file, which is the branch. It is set in
    /// `Typo.codeSmall`, 11 point monospaced, and SF Mono advances 0.6 em, so a character is 6.6
    /// points and 520 less the card's two 12 point gutters is 75 of them. The longest branch in
    /// this repository is 44 characters, and Bloom's own generated ones are `agent/` plus a date
    /// and a slug. So the ceiling clears a real branch name with room, and what it refuses is a
    /// branch nobody typed. There the head truncation the branch line already does is the right
    /// answer anyway: the tail is the half that says which branch it is.
    public static let ceiling: CGFloat = 520

    /// The width to draw a card whose content wants `content` points.
    ///
    /// The view clamps itself with the same two bounds, so this exists for the PANEL rather than
    /// for the drawing: what the panel is sized from is `NSHostingView.fittingSize`, which comes
    /// back a fraction over a whole point, and comes back zero for a hosting view that has not
    /// laid out yet. A zero would be a panel with a shadow and nothing in it. Everything that is
    /// not a width lands on the floor instead.
    ///
    /// Rounded up, because a panel on a half point draws its rim across two rows of pixels.
    public static func fits(content: CGFloat) -> CGFloat {
        guard content.isFinite else { return minimum }
        return min(max(content.rounded(.up), minimum), ceiling)
    }
}
