import SwiftUI

/// The inspector's spacing scale.
///
/// One set of numbers rather than a literal per call site, because two stacked bars and the pane
/// under them only read as one column if their rows, insets and gutters agree.
///
/// The shared values are the window's, not the inspector's own: a file row and a sidebar row are
/// the same kind of thing and used to sit a point or two apart because each column kept its own
/// copy of the number. What is left here is genuinely local to a diff.
enum InspectorLayout {
    /// Between two things that belong to each other.
    static let tight = Metrics.spacingTight
    /// Between controls in a row.
    static let gap = Metrics.spacing
    /// The inset a list row keeps from the edge of the pane.
    static let inset = Metrics.inset
    /// The tab row, and every other strip in the column.
    static let barHeight = Metrics.barHeight
    /// The pull request strip, which is taller than the rest of them on purpose.
    ///
    /// Derived from the type it holds, measured rather than guessed. `NSFont` reports the line
    /// height of each rung on this system as: `.title3` bold 18, `.subheadline` medium 13. The
    /// headline is `Typo.heading` and the detail under it is `Typo.caption`, a point apart, so
    /// the text block is 18 + 1 + 13 = 32. Eight points of air above and below it is 48.
    ///
    /// The button is the shorter of the two things in the band: a `.regular` `.borderedProminent`
    /// button measures 24 points on this system, so it sits with twelve points either side and the
    /// text is what sets the height.
    ///
    /// It was 44, and the arithmetic written here for it described a design that never shipped: it
    /// claimed a 13 point headline where the code drew `Typo.captionEmphasis`, which is 11. The
    /// headline was therefore two points SMALLER than the file names in the list below it, which
    /// is why the strip read as a caption over the column rather than as the top of it.
    static let pullRequestBarHeight: CGFloat = 48
    /// The pull request number and the arrow beside it, drawn as one outlined control.
    ///
    /// Measured off the control this one is meant to match rather than chosen: 24 points tall,
    /// 12 point text (`Typo.label`), and a rim at twenty percent of the state's own colour. The
    /// badge it replaces was 17 points tall, 11 point text and filled, which read as a sticker on
    /// the band rather than as something to press, and half of it was not pressable at all.
    ///
    /// The inset is the horizontal padding of each half, so the seam between them sits at the
    /// middle of the pair rather than being a third measurement. See `PullRequestBadge`.
    static let badgeHeight: CGFloat = 24
    static let badgeInset: CGFloat = Metrics.spacingWide
    static let badgeStrokeOpacity: Double = 0.2
    /// A meaning colour used as a background rather than as ink. One value, so a green badge and a
    /// blue chip carry the same weight.
    static let tintOpacity: Double = 0.12
    /// The pull request strip's own wash, which is denser than `tintOpacity`.
    ///
    /// A chip is a mark a centimetre wide and twelve percent is plenty to colour one. This wash
    /// runs the whole width of the pane and has to read as a coloured BAND from across the room,
    /// which is the whole reason the bar owns the colour rather than its contents. At twelve
    /// percent the teal band measured `#E2EFEE` on white: a step of thirteen units off the surface
    /// beside it, which is not a colour, it is a smudge. Eighteen measures `#D3E7E4`.
    static let bandOpacity: Double = 0.18
    /// The same wash on a pull request that is finished.
    ///
    /// Merged and closed are reports, not requests. They keep their colour, because "did this
    /// land" is worth answering at a glance, and they give up the volume, because there is nothing
    /// left to do about either of them and the band is competing with a diff.
    static let bandOpacityQuiet: Double = 0.08
    /// Status glyphs share one box, so the names beside them line up whichever symbol lands in it.
    ///
    /// **Leading aligned, everywhere it is used.** The box is what makes the names line up; what
    /// makes the ROWS line up with everything else in the column is where the first mark inside
    /// the box lands. `ChangedFileRow` fills its box with a letter on a rounded plate, so its ink
    /// starts at the box's own edge; the two trees and the checks list put a symbol in the same
    /// box, and a symbol centred in it starts its ink wherever that symbol happens to be wide.
    /// Measured at the pane's default width: the changed files tab drew its first mark 10 points
    /// inside the pane, matching the tab row's control and the strip's badge above it, and the
    /// all files tab drew its first mark at 14.7, because `doc` is about nine points wide in a
    /// sixteen point box. Switching tabs moved the column. Leading alignment is what makes the
    /// box's edge and the ink's edge the same number.
    static let glyphWidth: CGFloat = 16
    /// One level of indent in the file tree. Exactly one glyph box, so a row's chevron starts
    /// where its parent's chevron ended and the column of names steps in visibly. It was 12, which
    /// is less than the glyph it is meant to clear and read as a ragged margin rather than as a
    /// level. Any wider and a path three deep leaves no room for a filename at 280pt.
    static let indentStep: CGFloat = 16
}

extension View {
    /// A small control in one of the inspector's strips: the pull request bar, the tab row, the
    /// file header.
    ///
    /// Flat until it is on or under the pointer, which is what `.accessoryBar` draws and what a
    /// strip of small controls looks like everywhere else on this platform. The default button
    /// toggle style boxes each control in its own bordered rectangle, so a header carrying four of
    /// them read as a row of buttons parked on top of the file it is about rather than as part of
    /// the bar, and the boxes outweighed the filename beside them.
    ///
    /// `.borderless` is flat too, but it draws its glyph in the accent colour, which makes a
    /// resting toggle look pressed. This keeps every glyph in the strip at label weight and lets
    /// the fill alone say which of them is on.
    func inspectorBarControl() -> some View {
        buttonStyle(.accessoryBar)
            .controlSize(.small)
    }
}
