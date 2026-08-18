import SwiftUI

/// The one grid every block on Home is laid out in.
///
/// It exists so the shortlist at the top and the project blocks below it cannot drift into two
/// different column widths, which is what makes a page of cards read as a page rather than as a
/// stack of unrelated lists. Adaptive columns are also the whole answer to the empty right half
/// Home used to have: one card in a fixed narrow column leaves the pane unused, whereas one card
/// in an adaptive grid takes the width it is given.
struct HomeCardGrid: View {
    var workspaces: [HomeWorkspace]
    @Binding var hovered: String?
    var onSelect: (HomeWorkspace) -> Void

    /// The floor is what a workspace name and a branch need before either starts truncating; the
    /// ceiling stops a two-card row on a wide window from drawing two banners.
    private static let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 400), spacing: Metrics.gutter)
    ]

    var body: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Metrics.gutter) {
            ForEach(workspaces) { entry in
                HomeWorkspaceCard(
                    entry: entry,
                    isHovered: hovered == entry.id,
                    action: { onSelect(entry) }
                )
                .onHoverChange { inside in
                    hovered = inside ? entry.id : (hovered == entry.id ? nil : hovered)
                }
            }
        }
    }
}
