import SwiftUI
import BloomCore

/// Every row that can appear under a project, stacked at the pane's real width with a rule down
/// the column their names are supposed to share.
///
/// It exists because the claim this layout makes is a claim about **one column across six row
/// types**, and no single file shows it: the header is `RepoHeaderRow`, the ordinary row is
/// `WorkspaceRow` under `SidebarWorkspaceRow`'s indent, the empty line is `SidebarEmptyNoticeRow`,
/// the row a worktree is being cut behind is `PendingWorkspaceRow`, a crew member's is
/// `CrewSidebarRow` and a subagent's is `SubagentSidebarRow`. Each was moved once and each could
/// drift alone. A picture with a rule on it is the only thing that catches the sixth one being
/// three points out.
///
/// The rule is drawn at `SidebarMetrics.nameColumn`, which is derived from the header's own
/// `HStack` rather than measured, so the page cannot flatter the layout: if the tile changes size
/// and only some of the rows follow, the rule moves with the header and the stragglers are left
/// beside it. A second, quieter pair of rules brackets `SidebarMetrics.markColumn`, which is the
/// gutter the status marks were left in when the names moved right.
///
/// Rendered offscreen by `--snapshot` as `sidebar-indent-<appearance>.png`, and in a window with
///
///     Bloom --snapshot-gallery <dir> --gallery sidebar-indent
///
/// **Nothing on this page is running**, which is a layout decision rather than an oversight. The
/// running mark is layer backed, so `ImageRenderer` paints SwiftUI's yellow placeholder over it
/// and the offscreen picture, which is the one an agent can take without filming the owner's
/// screen, would lose the row it most needs to measure. The marks that move are photographed in
/// `RunningGlyphGallery` and `SubagentRowGallery`; what is measured here is where they sit.
struct SidebarIndentGallery: View {
    var app: AppModel

    /// Nothing is ever renamed on this page. It is here because `WorkspaceRow` takes the binding
    /// the whole list shares, and a gallery that passed it a constant would be drawing a row the
    /// pane does not have.
    @State private var renaming: WorkspaceID?

    private static let repo = Repo(
        id: RepoID("bloom"), name: "bloom", path: "/Users/x/dev/bloom"
    )

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Sidebar indents")
                .font(Typo.title)
            Text("Every name under a project starts on the project's own name.")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            HStack(alignment: .top, spacing: 24) {
                pane("A project with work in it") {
                    header(count: 3)
                    workspace(name: "sidebar name column", unread: true)
                    workspace(name: "checks that go quiet", changed: true)
                    crew
                    subagent
                    PendingWorkspaceRow(pending: PendingWorkspace(
                        id: WorkspaceID("pending"), repoID: Self.repo.id, name: "one door out"
                    ))
                    .frame(height: 32)
                }

                pane("A project with none") {
                    header(count: 0)
                    SidebarEmptyNoticeRow(isFiltered: false)
                        .frame(height: 32)
                    SidebarEmptyNoticeRow(isFiltered: true)
                        .frame(height: 32)
                }
            }
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.windowBackground)
        .environment(app)
    }

    /// The pane at its 260 point default, which is the only width these rows are ever judged at,
    /// with the columns drawn over whatever is in it.
    private func pane(
        _ title: String, @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                rows()
            }
            .frame(width: 260, alignment: .leading)
            .background(Palette.surface)
            .overlay(alignment: .leading) { columns }
        }
    }

    /// The three lines the whole page is about: the mark's gutter, bracketed, and the name column
    /// through it.
    private var columns: some View {
        ZStack(alignment: .leading) {
            rule(at: SidebarMetrics.rowIndent, isFaint: true)
            rule(at: SidebarMetrics.rowIndent + SidebarMetrics.markColumn, isFaint: true)
            rule(at: SidebarMetrics.nameColumn, isFaint: false)
        }
        .allowsHitTesting(false)
    }

    private func rule(at x: CGFloat, isFaint: Bool) -> some View {
        Rectangle()
            .fill(Palette.accentFill.opacity(isFaint ? 0.25 : 0.7))
            .frame(width: 1)
            .offset(x: x)
    }

    private func header(count: Int) -> some View {
        RepoHeaderRow(
            repo: Self.repo,
            hasUnreadWork: count > 0,
            workspaceCount: count,
            onCreateWorkspace: { _ in }
        )
        .frame(height: 32)
    }

    private func workspace(name: String, unread: Bool = false, changed: Bool = false) -> some View {
        WorkspaceRow(
            workspace: Workspace(
                repoID: Self.repo.id,
                name: name,
                branch: name.replacingOccurrences(of: " ", with: "-"),
                path: "/tmp/worktree",
                baseBranch: "main",
                createdAt: Self.now,
                lastActivityAt: Self.now,
                additions: changed ? 41 : 0,
                deletions: changed ? 12 : 0,
                changedFiles: changed ? 4 : 0,
                unread: unread
            ),
            isRunning: false,
            renaming: $renaming,
            onArchive: { _ in }
        )
        .padding(.leading, SidebarMetrics.rowIndent)
        .frame(height: 32)
    }

    /// A crew member between turns, so the page draws its ring rather than the pulsing dot an
    /// offscreen render cannot photograph. It shares the subagent's indent, which is the whole
    /// reason it is on this page: the two rows are drawn by different files and each could drift
    /// alone.
    private var crew: some View {
        CrewSidebarRow(row: CrewRow(Session(
            workspaceID: WorkspaceID("w1"),
            parentSessionID: SessionID("s0"),
            title: "cascade-read",
            createdAt: Self.now,
            updatedAt: Self.now
        )))
        .frame(height: 32)
    }

    /// A subagent that has finished, so the page draws a tick rather than the mark an offscreen
    /// render cannot photograph. Its own indent is the last one this pane has.
    private var subagent: some View {
        SubagentSidebarRow(row: SubagentRow(Subagent(
            id: SubagentID("1"),
            description: "Find every row under a project",
            type: "Explore",
            state: .completed,
            summary: "five of them",
            outputFile: "/x",
            elapsedSeconds: 14
        )))
        .frame(height: 32)
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    static let sidebarIndent = Gallery(
        name: "sidebar-indent",
        title: "Sidebar indents",
        size: CGSize(width: 620, height: 320),
        needsFocus: false,
        view: { app in AnyView(SidebarIndentGallery(app: app)) }
    )
}
