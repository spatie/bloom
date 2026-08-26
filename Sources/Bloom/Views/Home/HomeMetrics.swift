import SwiftUI

/// The two numbers that keep Home's strip and Home's rows in one column.
///
/// They are here rather than in `Metrics` for the same reason `SidebarMetrics` exists: they
/// describe one pane's internal rhythm, and the relationship between them was arrived at by
/// measuring a window capture rather than by reasoning from the spacing scale.
enum HomeMetrics {
    /// A row in Home's list, which is two lines rather than the sidebar's one.
    ///
    /// Not `Metrics.rowHeight`, which is the 28 points AppKit gives a source list row: that is the
    /// pitch for a line of text and a glyph, and this row carries a name over a project and a
    /// branch. Forty-two is those two lines at their own leading plus the clearance above and below
    /// that the sidebar's row has, measured rather than derived, and it is the number to re-measure
    /// if either line changes rung.
    static let rowHeight: CGFloat = 42

    /// What a row asks `List` to keep clear of the pane's edges.
    ///
    /// Not what it gets. `.listStyle(.inset)` adds an inset of its own on top of `listRowInsets`
    /// and does not expose it: measured off a window capture, a row's rail is drawn 23 points from
    /// the pane's leading edge while this asks for 8, and the last ink on the trailing side lands
    /// 25 points in.
    static let rowInset: CGFloat = Metrics.spacingWide

    /// What the strip above the list is padded by.
    ///
    /// `Metrics.pane`, which is where a full-width pane of content sits, and which happens to be
    /// within a point of where `List` puts the rows underneath at `rowInset`. That agreement is
    /// luck rather than arithmetic, so it is measured rather than derived, and it is the reason
    /// this constant exists instead of the call site simply saying `Metrics.pane`: if the list
    /// style ever changes, the number to re-measure is this one, and the comment saying so has to
    /// be somewhere the next person will look.
    ///
    /// Measured after the change: the search field's leading edge and the rows' rail both fall on
    /// 23 points, and the readout's trailing edge and the age column both fall on 25.
    static let gutter: CGFloat = Metrics.pane
}
