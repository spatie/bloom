import SwiftUI

/// How a sidebar row lays out its leading mark and its text.
///
/// The obvious way to write these rows is a plain `Label`, and that is what they were. The reason
/// it cannot stay that way is the fold animation: a `Label` left in the list's own hands puts its
/// icon in a column the LIST draws, and that column is not carried by the row's insertion. So a
/// project expanding animated the names in while the marks beside them were simply absent, and
/// they appeared afterwards, against rows that had already stopped moving. Measured with the fold
/// slowed to 1.2 seconds: at 225ms every name was drawn in full and travelling, and not one glyph
/// was on screen; the same capture with the same row rebuilt as a plain `HStack` showed every
/// glyph travelling with its name. `.transaction { $0.animation = nil }` on the icon was tried
/// first and changed nothing, which is what ruled out the icon merely animating on a different
/// schedule: it was not being drawn at all.
///
/// So the row lays the two out itself, and this type is what keeps every row that does so in
/// agreement. `WorkspaceRow` and the notice that stands in for it when a project is empty both
/// wear it, which is what stops them drifting apart the way two hand-built stacks would.
///
/// The two columns are the project header's, term for term. The mark takes the tile's box and the
/// gap after it is the header's own, so a row laid out with this and given
/// `SidebarMetrics.rowIndent` puts its mark under the project's mark and its name under the
/// project's name, which is `SidebarMetrics.nameColumn`. The numbers used to reproduce what the
/// system's label geometry happened to measure at, and that is what made them a pair of literals
/// nothing could move.
///
/// **The image scale has come off this style, and that is a fix rather than a tidy up.** A sidebar
/// `Label` raises it for the icon slot and this style raised it as well, on a measurement that was
/// read the wrong way round: `arrow.triangle.branch` came out 13.5 points across with it and 10.5
/// without, and the larger was taken for the right one. What it did was push every mark past the
/// 13 point box this column is aligned on, and only in the sidebar, since Home, the legend and the
/// hover card draw the same marks with no scale at all. One state, two sizes, depending which pane
/// it was read in. The marks carry their own scale now, in `WorkspaceStatusGlyph` and
/// `SubagentMarkGlyph`, which is where a decision about how large a mark is belongs.
struct SidebarRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Metrics.spacing) {
            configuration.icon
                // Wider than the mark it holds, because it is the tile's box rather than the
                // mark's: the glyph is centred in the project's column instead of hung off its
                // leading edge.
                .frame(width: SidebarMetrics.markColumn, height: Metrics.glyph)
            configuration.title
        }
    }
}
