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
    /// Wide enough for the chevron and nothing else. It is what pushes the project's tile far
    /// enough right that a workspace row's status mark falls between the two, which is the
    /// relationship that makes a project read as containing its rows rather than as standing in
    /// the same column as them.
    static let caretGutter: CGFloat = 11

    /// How large the chevron itself is drawn. Roughly a five point mark: the smallest thing in
    /// the pane, because it is furniture rather than content.
    static let caretSize: CGFloat = 9
}
