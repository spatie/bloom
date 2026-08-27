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
/// The image scale is not decoration and does not come from any of that: a sidebar `Label` raises
/// it for the icon slot, and without it the mark came out 10.5 points across rather than 13.5.
struct SidebarRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Metrics.spacing) {
            configuration.icon
                .imageScale(.large)
                // Wider than the mark it holds, because it is the tile's box rather than the
                // mark's: the glyph is centred in the project's column instead of hung off its
                // leading edge.
                .frame(width: SidebarMetrics.markColumn, height: Metrics.glyph)
            configuration.title
        }
    }
}
