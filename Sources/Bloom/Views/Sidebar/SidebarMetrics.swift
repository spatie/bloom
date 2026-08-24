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
    /// The space above a project's row that a `Section` header used to be given for nothing.
    ///
    /// Measured off a window capture of the sections: one header's 32 point pitch was 13 points of
    /// section spacing above a drawing band of 19. The pane draws one flat run of rows now (see
    /// `SidebarView`), so a project header is handed the full 32 points and centres its content in
    /// them, and without this the gap that says a new project starts here would be gone.
    ///
    /// It is a padding INSIDE the row rather than extra height on top of it, and the number is
    /// what makes that true. Measured on the flat run through the accessibility tree, which
    /// reports every row's real height: a project header draws 24 points of content, so 8 above it
    /// is exactly the 32 the row already had. Thirteen made the row 37 and put every project five
    /// points out of step with the rows above it.
    static let headerLead: CGFloat = 8

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

    /// How far a subagent's row is pushed right of the workspace row it belongs to.
    ///
    /// The same step again, so the pane's three levels are evenly spaced and a subagent's mark
    /// falls where a workspace's name begins. It is the last step this pane gets: a fourth would
    /// leave a name six characters wide at the 260 point default, which is why `SubagentRow.rows`
    /// draws a subagent's own children at this indent rather than one further in.
    static let subagentIndent: CGFloat = caretGutter

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

    /// The click target of a control that lives on a workspace row, such as the archive button
    /// that is revealed under the pointer.
    ///
    /// Deliberately small. A destructive control at the trailing edge of a row you are about to
    /// click has to be unambiguous, and every point it grows is a point of the row it steals. It
    /// is square and a little larger than the mark it draws, so it is comfortable to hit without
    /// reaching towards the name.
    static let rowButton: CGFloat = 20

    /// How far a hidden project's header is played down when the owner has asked to see the
    /// hidden ones.
    ///
    /// One opacity over the whole header, so the tile and the name step back together. Conductor
    /// draws its hidden repositories at the same size and in the same place as the rest, in less
    /// contrast, and that restraint is the whole point: a hidden project is still a project.
    ///
    /// A little under half, which is the step this pane already uses between something that is
    /// there and something that is barely there. Lower and the tile's own colour goes muddy
    /// against the sidebar material in dark mode; higher and the two ranks are not tellable apart
    /// at a glance, which is the one thing this has to do.
    static let hiddenDim: Double = 0.45

    /// How large the chevron itself is drawn. Roughly a five point mark: the smallest thing in
    /// the pane, because it is furniture rather than content.
    static let caretSize: CGFloat = 9
}
