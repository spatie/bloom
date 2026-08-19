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
    /// It carries the state of the work as a headline with its numbers under it, and the one
    /// prominent button in this column. Two lines of text is 30 points at the sizes used here
    /// (a 13 point headline, a point of leading, an 11 point detail), and a regular button is 24,
    /// so 44 leaves seven points of air above and below whichever of the two is taller. At the 32
    /// the tab row uses, the button had to drop to `.small` and the detail line had nowhere to go,
    /// which is why the strip read as a caption rather than as the top of the column.
    static let pullRequestBarHeight: CGFloat = 44
    /// A meaning colour used as a background rather than as ink. One value, so a green badge and a
    /// blue chip carry the same weight.
    static let tintOpacity: Double = 0.12
    /// The same meaning colour on something that sits ON the wash above, such as the pull request
    /// number. One step denser, or the chip disappears into the bar it is drawn on.
    static let tintOpacityStrong: Double = 0.24
    /// Status glyphs share one box, so the names beside them line up whichever symbol lands in it.
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
