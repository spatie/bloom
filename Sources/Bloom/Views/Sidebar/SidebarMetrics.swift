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
    /// the pane's own edge, and the rows underneath start on the far side of it, so the two
    /// numbers are one number.
    static let caretGutter: CGFloat = 11

    /// How far a workspace row, and everything else that hangs under a project, is pushed right of
    /// the leading edge the list hands it.
    ///
    /// Where the project's own tile starts: past the chevron's gutter and the gap after it, which
    /// are the first two terms of `RepoHeaderRow`'s own `HStack`. Written as those terms rather
    /// than as the seventeen points they come to, because the header's layout is what this has to
    /// agree with and a literal here would agree with it only until the tile changed size.
    ///
    /// Two arrangements came before it and both are worth knowing about. The mark first fell
    /// BETWEEN the chevron and the tile, which reads as a third column rather than as nesting:
    /// the rows began left of the thing they belong to. It then moved to the chevron's gutter, so
    /// the mark sat inside the tile's column and every name under a project sat five points right
    /// of the project's own. That is the one this replaces, and what was wrong with it is the five
    /// points: two text columns, one of them a rank of names and the other a single heading, close
    /// enough to look like a mistake and far enough not to line up. See `nameColumn`.
    static let rowIndent: CGFloat = caretGutter + Metrics.spacing

    /// The box a row's status mark is centred in, which is the project's tile exactly.
    ///
    /// The tile's own width, so the marks run down the middle of the column the project's mark is
    /// drawn in. That column is what the icon vacated when the names moved right, and putting the
    /// marks in it is what keeps them scannable: a reader looking for the one workspace that is
    /// running reads one narrow strip, and the names beside them are a second strip that starts
    /// under the project's name.
    ///
    /// How large the marks inside it are drawn is NOT here, and deliberately. `Metrics.glyph`,
    /// `Metrics.glyphInk` and `Metrics.dot` are one family, and Home, the tab strip and the
    /// transcript read them as well as this pane does: a size named after one pane and used from
    /// another is how the two drift, which is the argument `Metrics.headerButton` already carries.
    /// This is the column the marks are centred in; those three are the marks.
    static let markColumn: CGFloat = Metrics.repoIcon

    /// Where a project's name begins, and with it every name drawn under that project.
    ///
    /// The owner asked for this: the rows used to start under the project's ICON, which put a
    /// workspace's name a tile and a gap right of the project's and left the pane with two text
    /// columns. One column reads as the project naming the things under it. So a row spends the
    /// tile's width on its status mark instead and its name lands here, on the project's own.
    ///
    /// Derived rather than measured, and that is the point. It is the header's `HStack` written
    /// out: the chevron's gutter, the gap, the tile, the gap. Resize the tile and the project's
    /// name and every name beneath it move together, which a number chosen off a capture would
    /// not do.
    static let nameColumn: CGFloat = rowIndent + markColumn + Metrics.spacing

    /// How far a subagent's row is pushed right of the workspace row it belongs to.
    ///
    /// The chevron's gutter, so a subagent's mark and its name each sit one step right of the
    /// workspace's. It is a real step because it has to be: a workspace row shares the project's
    /// name column rather than stepping in from it, so the only thing left saying a subagent is
    /// inside its workspace is this indent. It is also the last step this pane gets, because a
    /// fourth would leave a name six characters wide at the 260 point default, which is why
    /// `SubagentRow.rows` draws a subagent's own children at this indent rather than one further
    /// in.
    static let subagentIndent: CGFloat = caretGutter

    /// Where a crew member's row begins, which is where its workspace's name begins.
    ///
    /// Not `rowIndent + subagentIndent`, which is what it was and what the owner sent back. A
    /// subagent of a turn steps one gutter in from the workspace row, which puts its mark between
    /// the workspace's mark and the workspace's name: a third column, five points from one and a
    /// tile from the other, reading as neither. A crew member instead starts its mark on
    /// `nameColumn`, so the column above its mark holds exactly one thing, the name of the
    /// workspace it is working in.
    ///
    /// Half the mark's box back off `nameColumn`, so the mark is CENTRED on that column rather
    /// than starting at it. `SidebarRowLabelStyle` centres a row's mark in a `markColumn` wide
    /// box, so an indent of `nameColumn` on the nose puts the dot half a tile right of the letter
    /// it is meant to hang under, which is the same near miss in the other direction.
    ///
    /// Derived from `nameColumn` rather than measured, for the reason that constant gives: resize
    /// the project tile and the whole ladder moves together.
    static let crewIndent: CGFloat = nameColumn - markColumn / 2

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

    /// How far a selected row's fill is held off each edge of the pane.
    ///
    /// The table used to draw its own highlight and inset it for us. The fill is Bloom's now (see
    /// `SidebarSelectionFill`), and a `listRowBackground` is handed the whole row rect, so the
    /// inset has to be put back or the selection runs into the window's edge.
    ///
    /// Ten points, measured off a capture of the pane as AppKit drew it: the band ran from 10 to
    /// 249 in a 260 point sidebar. Measured rather than chosen, so the change is a change of
    /// colour and not of layout.
    static let selectionInset: CGFloat = 10

    /// How large the chevron itself is drawn. Roughly a five point mark: the smallest thing in
    /// the pane, because it is furniture rather than content.
    static let caretSize: CGFloat = 9
}
