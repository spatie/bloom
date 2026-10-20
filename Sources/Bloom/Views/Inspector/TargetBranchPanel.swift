import SwiftUI
import BloomCore

/// The branch a workspace without a pull request is measured from and would open one against,
/// searched the way the create window searches its bases. See `BaseBranchChange`.
///
/// The branches are listed when the panel opens rather than when the strip appears, so arriving
/// on a workspace costs no git at all.
struct TargetBranchPanel: View {
    var worktree: String
    var branch: String
    var baseBranch: String
    var onPick: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Nil until the listing is in, which is a different sentence from a repository with nothing
    /// else to offer.
    @State private var options: [String]?
    @State private var query = ""
    @State private var selected: WorkspaceSource?

    /// Narrower than the create window's panel, which also lays out pull request titles.
    private static let width: CGFloat = 360
    private static let role = WorkspaceSourceRow.Role(glyph: "arrow.triangle.branch", verb: "Target")

    private var matches: WorkspaceSourceMatches {
        WorkspaceSourceOffering(baseBranches: options ?? []).search(query: query)
    }

    var body: some View {
        let matches = self.matches
        VStack(alignment: .leading, spacing: 0) {
            Text("Changes are measured from this branch, and a pull request targets it.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Metrics.spacingWide)
            Hairline()
            WorkspaceSourceList(
                matches: matches,
                tab: .newBranch,
                query: $query,
                selected: $selected,
                emptyText: options == nil ? "Reading branches…" : "No other branches",
                rowRole: Self.role,
                placeholder: "Search branches",
                onPick: pick(_:),
                onEscape: { dismiss() }
            )
        }
        .frame(width: Self.width)
        .task {
            options = await BaseBranchChange.load(repoPath: worktree, excluding: branch)
            let current = WorkspaceSource.newBranch(from: baseBranch)
            selected = self.matches.settled(after: current, in: .newBranch)
        }
    }

    private func pick(_ source: WorkspaceSource) {
        dismiss()
        onPick(source.name)
    }
}
