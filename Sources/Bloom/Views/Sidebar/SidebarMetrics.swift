import SwiftUI

/// The measurements that make the source list one column rather than three.
///
/// Taken off a reference render of this window with the sidebar at its 260 point default. They
/// are here rather than in `Metrics` because they describe one pane's internal rhythm and were
/// arrived at by measuring a picture, not by reasoning from the scale. Candidates for promotion
/// once the rest of the window has been measured the same way.
///
/// There is deliberately no row height here. A `List` with `.listStyle(.sidebar)` sizes its rows
/// itself and ignores every lever offered for changing that: `listRowInsets`, an explicit
/// `frame(height:)` on the row, `defaultMinListRowHeight` and `controlSize` were each captured
/// and each left the pitch at exactly 32 points. The reference draws 28. Reaching it would mean
/// leaving `.listStyle(.sidebar)`, and with it AppKit selection, keyboard navigation and the
/// standard insets, which is a far worse trade than four points. What was in reach is the rhythm
/// being EVEN, and that is what the header's own padding was spent on.
///
/// A project header does NOT get those 32 points to draw in. Measured off a window capture, one
/// header's 32 point pitch is 13 points of section spacing above a drawing band of 19, and the
/// band CLIPS: content offset up into the spacing is cut off at the band's top edge, so a header
/// cannot be nudged away from the row below it. Whatever the header draws has to fit in 19 points
/// and is centred there, which is why `Metrics.headerButton` is 15 tall rather than 18. Anything
/// taller than 19 does not overflow, it pushes the whole row taller and breaks the pitch.
enum SidebarMetrics {
    /// The gutter the project's disclosure chevron sits in, at the leading edge of a header.
    ///
    /// Wide enough for the chevron and nothing else. It is what pushes the project's tile clear of
    /// the pane's own edge, and it is the step the rows underneath are indented by, so the two
    /// numbers are one number.
    static let caretGutter: CGFloat = 11

    /// How far a workspace row, and the notice that stands in for one, are pushed right of the
    /// leading edge the list hands them.
    ///
    /// The chevron gutter, so a row starts where the project's own tile starts rather than left of
    /// it. Measured on the drawn marks: the tile spans 31 to 47 points from the pane's edge, and
    /// with this indent a row's status mark is drawn from 33.5 to 46.5, sitting inside the tile's
    /// column instead of in a column of its own two points to the left of it. The workspace names
    /// then start five points right of the project's name.
    ///
    /// This reverses an earlier arrangement, where the mark deliberately fell BETWEEN the chevron
    /// and the tile. That reads as a third column rather than as nesting: the rows began left of
    /// the thing they belong to. The owner compared the two against Conductor, where the rows are
    /// indented past the project's icon, and asked for this one.
    static let rowIndent: CGFloat = caretGutter

    /// The gap between a workspace row's status mark and the name beside it.
    ///
    /// Measured off the rows as the system's own `Label` drew them, so that `SidebarRowLabelStyle`
    /// could take the layout over without moving anything: the mark's ink ran from 33 to 46.5
    /// points off the pane's edge and the name's ink began at 57.5.
    static let markToText: CGFloat = 10.5

    /// What the system's `Label` was insetting a sidebar row's icon column by, on top of the row
    /// indent, and which `SidebarRowLabelStyle` has to put back by hand now that it does the
    /// layout itself. Measured: without it every mark and name sat 6.5 points left of where they
    /// had been, which would have unpicked the alignment `rowIndent` was chosen for.
    static let markInset: CGFloat = 6.5

    /// How large the chevron itself is drawn. Roughly a five point mark: the smallest thing in
    /// the pane, because it is furniture rather than content.
    static let caretSize: CGFloat = 9
}
