import SwiftUI
import BatonCore

/// What the glyph at the head of each sidebar row means.
///
/// Every state, not a chosen four. The list is built from `WorkspaceStatus.allCases` and draws the
/// mark with `WorkspaceStatusGlyph`, which is the row's own drawing, so a legend that explains a
/// mark the sidebar no longer draws is not something this file can produce. The hand-kept version
/// named four of the thirteen states and had already drifted on the colour of one of them.
///
/// Split where the answers come from: the first block is what Baton can see in the worktree, the
/// second is what GitHub said. That is the split the user is already making when they scan the
/// column, and it is `WorkspaceStatus.describesPullRequest` rather than a second list here.
struct SidebarLegend: View {
    /// Wide enough for the longest explanation on one line, narrow enough to read as a legend.
    private static let width: CGFloat = 240

    private static let local = WorkspaceStatus.allCases.filter { !$0.describesPullRequest }
    private static let remote = WorkspaceStatus.allCases.filter(\.describesPullRequest)

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            section("In the workspace", states: Self.local)
            section("On GitHub", states: Self.remote)
        }
        .padding(Metrics.gutter)
        .frame(width: Self.width)
    }

    private func section(_ title: String, states: [WorkspaceStatus]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(title)
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityAddTraits(.isHeader)

            ForEach(states, id: \.self) { status in
                HStack(spacing: Metrics.spacingWide) {
                    // The mark is the thing being explained, so the sentence beside it is the whole
                    // accessible content of the row.
                    WorkspaceStatusGlyph(status: status)
                        .accessibilityHidden(true)
                    Text(status.label)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
