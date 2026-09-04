import CoreGraphics

/// How wide the search panel is drawn, where it hangs, and how far the window behind it is taken
/// down.
///
/// # Why the width left the view
///
/// It was `SearchPanelView.width`, a flat 560. That is a reasonable card in a window at the
/// minimum and a small one adrift in a lot of room in the window the owner actually works in,
/// which is around 1,730 points wide: the panel took under a third of it and read as a dialogue
/// that had forgotten where it was. His words were "we have all this space, make it a bit wider".
///
/// A proportion alone is worse than a constant, in both directions. It shrinks below what a
/// workspace name, its project and an age need on one line, and on a 3,440 point display it draws
/// a field a thousand points wide with a row whose title sits at the far left and whose date sits
/// at the far right, which stops being readable as one row. So it is a proportion clamped at both
/// ends, and the clamp is the part worth writing down.
///
/// The numbers are read off the widths Bloom is actually used at rather than chosen for looking
/// about right. `WindowWidths.minimum` puts the narrowest window with an inspector at 1,122 points
/// of content and the narrowest without one at 841; the scene opens at 1,440; the owner's is
/// 1,730. At 0.42 those come out 560 (clamped up from 471), 560 (clamped up from 353), 605 and
/// 727. A 27 inch display at 2,560 and an ultrawide at 3,440 both clamp down to 800.
///
/// # Why the panel is not centred on the centre pane
///
/// The dim, the ground that takes a click outside, and the card itself are one rectangle now, and
/// it is the window's rather than the centre column's. See `SearchPanelWindowOverlay`. That is
/// what these numbers are reckoned against: `inWindow` is the width of the whole window, not of
/// the pane the transcript happens to be in.
public enum SearchPanelLayout {
    /// What the panel has always been, and the floor it may never go under. Wide enough for a
    /// workspace name, its project and an age on one line.
    public static let minimumWidth: CGFloat = 560

    /// And the ceiling. A row this wide already puts a title and a date a long way apart; wider is
    /// a field somebody has to move their eyes along rather than read.
    public static let maximumWidth: CGFloat = 800

    /// The share of the window the panel takes between those two.
    public static let proportion: CGFloat = 0.42

    /// What is left either side at the widest, so a panel in a narrow window still reads as placed
    /// rather than wedged. It only ever binds in a window narrower than 720, which this one cannot
    /// be: `WindowWidths` holds the content at 841 at the very least.
    public static let margin: CGFloat = 80

    /// How far below the top of the window's CONTENT the card hangs.
    ///
    /// Near the top rather than against it: a card flush with the title bar reads as part of the
    /// chrome, and this is a thing in front of the window rather than a thing attached to it. The
    /// title bar's own height is added to this by the overlay, so the card sits where it always
    /// sat even though the dim now starts higher up.
    public static let topInset: CGFloat = 56

    /// How far the window behind is taken down, in light.
    ///
    /// Enough to say the window behind is not the thing being used, and not so much that a person
    /// cannot read the workspace name they were looking at. It leaves the text behind at about ten
    /// to one against its ground, where undimmed it is fifteen.
    public static let dimLight: Double = 0.22

    /// And in dark, where it has to be nearly twice as much to say the same thing.
    ///
    /// # Why this is two numbers and not one
    ///
    /// It was one, and the comment on it argued for one: black in both appearances, because what
    /// the dim does is take light out of the ground rather than tint it. The ink is still right.
    /// The amount was not, and the pictures said so: a capture in dark read as barely dimmed at
    /// all, and the arithmetic behind that is not a matter of taste.
    ///
    /// At 22 per cent, the light ground loses 56 of its 255. The dark ground has no such light to
    /// lose: `PaletteInk.surface` is `#0A1A25` in dark, whose brightest channel is 37, so **even
    /// painting it solid black removes less than the light dim removes at 22 per cent.** No single
    /// opacity of black can move both grounds by the same amount, because one of them is not there
    /// to be moved. `SearchPanelLayoutTests` asserts exactly that, so the day the dark ramp
    /// changes the suite says whether the argument still holds.
    ///
    /// # Why black is still the ink
    ///
    /// The obvious alternative in dark is a light scrim, and it is wrong here. It would raise the
    /// ground towards the card, and the card standing above its ground is the whole of what the
    /// dim buys in dark: the panel is `#22292F`-ish glass over a `#0A1A25` window, so lifting the
    /// window costs the separation the scrim exists to create. Black keeps taking light out; there
    /// is simply less of it to take, so it has to take a larger share.
    ///
    /// # Where the number comes from
    ///
    /// Not from a percentage that sounds right. It is the heaviest black that leaves the window
    /// behind still readable, measured with `Contrast` against every ground this app draws text
    /// on. `surfaceRaised` is the worst of the three, and there the text behind clears
    /// `Contrast.textFloor` at 0.40 and does not at 0.45. So 0.40 it is, and the suite holds both
    /// halves of that sentence.
    ///
    /// What it buys, against the 0.22 it replaces: the ground goes down 15 of its 37 rather than
    /// 8, and the text that covers most of the window goes down 87 of its 218 rather than 48. The
    /// two appearances do not do the same thing to the same pixels, and they are not meant to. In
    /// light the ground goes grey and that is the signal; in dark the ground can barely move and
    /// everything drawn on it dims by nearly half instead. Both read as "this is in front", which
    /// is the only thing the dim has ever had to say.
    public static let dimDark: Double = 0.40

    /// The dim for one appearance.
    public static func dim(isDark: Bool) -> Double {
        isDark ? dimDark : dimLight
    }

    /// The width to draw the card at in a window this wide.
    ///
    /// The floor wins over the margin, deliberately. A window too narrow to give the minimum its
    /// margins is a window whose panel should still be readable, and the margin is a matter of
    /// looks where the minimum is a matter of the row fitting.
    public static func width(inWindow windowWidth: CGFloat) -> CGFloat {
        let wanted = min(max(windowWidth * proportion, minimumWidth), maximumWidth)
        let fits = max(minimumWidth, windowWidth - 2 * margin)
        return min(wanted, fits)
    }
}
