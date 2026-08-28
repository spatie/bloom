import SwiftUI
import BloomCore

/// The right hand column: what the agent changed, and what GitHub thinks of it.
///
/// Everything here is a thin arrangement of the pieces below it: the pull request strip, what it
/// has to say, the tab row, and whichever pane the tab row selected.
///
/// It shows no file contents. It used to: the list sat above a drawer that held the diff, and the
/// two shared the column's height, so a wide diff got a narrow pane and a long list got a short
/// one. Files open in the centre column now, which is where Conductor puts them and where there
/// is room for them, and this column went back to being a list of what changed.
struct InspectorView: View {
    let model: WorkspaceModel

    /// The one Connect GitHub sheet, presented from the column's root rather than from whichever
    /// control raised it, so the pull request strip and the checks tab share one presentation.
    @Bindable private var signIn = GitHubSignIn.shared

    @State private var pullRequestAnchor = HoverCardAnchor()

    var body: some View {
        VStack(spacing: 0) {
            PullRequestBar(model: model)
                .background { HoverCardAnchorReader(anchor: pullRequestAnchor) }
                .onHoverChange { inside in
                    let source = WorkspaceHoverCardPresenter.Source
                        .pullRequestBand(model.workspace.id)
                    if inside {
                        WorkspaceHoverCardPresenter.shared.pointerEntered(
                            source,
                            card: pullRequestCard,
                            anchor: { pullRequestAnchor.screenFrame },
                            side: .below
                        )
                    } else {
                        WorkspaceHoverCardPresenter.shared.pointerExited(source)
                    }
                }
                .onDisappear {
                    WorkspaceHoverCardPresenter.shared
                        .pointerExited(.pullRequestBand(model.workspace.id))
                }
            Hairline()

            // What the strip above just did, said in the column rather than in the band.
            //
            // Here rather than in the strip because the strip is one row tall and cannot grow:
            // see `PullRequestBar`. Here rather than below the tab row because it is the answer
            // to a button a few points above it, and an answer that appears under the tabs reads
            // as something about the list.
            if let notice = model.pullRequestNotice {
                InspectorNotice(notice: notice) { model.pullRequestNotice = nil }
                Hairline()
            }

            // The tab row, and the boundary between it and the pane, as one band.
            //
            // The rule is drawn INSIDE the row's own height rather than stacked under it, which
            // is what makes this column's first line the same line as the centre column's. A tab
            // strip is `Metrics.barHeight` tall including the rule that closes it off (see
            // `tabStripMaterial`, where the rule sits behind the tabs for a reason of its own), so
            // a row of the same height with a rule added below it ends one point lower than the
            // row beside it. Measured off a two times capture at 1440 by 900: the centre column's
            // rule ran from y=83 and this one from y=85, two points of step across the join, which
            // is exactly the point this row used to spend on the top edge plus the point the rule
            // used to add underneath.
            //
            // **This half of the rule is deliberately not lit**, and it was for a fortnight. The
            // busy signal used to run here too, off the same epoch as the centre column's, and the
            // report on it was "there seems to be two going, one in middle pane, one in right".
            // Both halves were right on their own terms and that was the problem: they shared a
            // period and therefore not a speed, so two crests set off from two leading edges at
            // two rates, and what the eye counted was two objects rather than one thing passing
            // behind a divider. See `ActivityRule` for the continuous version that was measured
            // and not built.
            InspectorToolbar(model: model)
                .overlay(alignment: .bottom) { Hairline() }

            // What the list below is measured from, when it is not measured from everything.
            //
            // Under the tab row because it is a fact about the pane beneath it. On both file tabs
            // rather than only on Changes: the All files tree marks the files that differ, and it
            // marks them off the same list, so a narrowed scope quietly takes marks off that tree
            // too. A tab where the scope has an effect is a tab where it has to be explained. The
            // checks list is GitHub's and owes nothing to any of this.
            if model.inspectorTab != .checks, model.diffScope.isNarrowed {
                DiffScopeBand(
                    scope: model.diffScope,
                    fileCount: model.changedFiles.count,
                    note: model.scopeNote
                ) {
                    model.setDiffScope(.all)
                }
                Hairline()
            }

            content
        }
        // Pinned to the top of whatever the column gives it, and filling the rest.
        //
        // `InspectorPane` hands this view a flexible frame, and a flexible frame CENTRES a child
        // that does not fill it. Every pane below the tab row is greedy except the empty states,
        // so a worktree with nothing changed in it drew the whole column floating in the middle
        // of the pane with the chrome colour showing above and below it. That was invisible while
        // the column began with a tab row and is not any more: the rule this view now draws is
        // the pane's top edge, and an edge that floats is worse than no edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.surface)
        // The column's own top edge.
        //
        // The pane is white and the band above it is the title bar, so without a rule the white
        // simply begins. Every other boundary in this window is a `Hairline` in `Palette.border`,
        // and this is the same rule at the same weight rather than a sixth kind of line.
        //
        // An overlay rather than the first row of the stack, and that is the whole of the
        // alignment fix. A row of its own takes a point of the column before the tab row starts,
        // so the tab row began a point lower than the centre column's, and the rule closing it
        // off a point lower again. Drawn over the top edge it costs the layout nothing and the two
        // columns start their first band on the same line.
        //
        // Drawn here rather than under the title bar strip, and never in both places. The strip is
        // only as wide as this pane and is not there at all on a workspace with no inspector, so a
        // rule belonging to it would be a line that comes and goes; the pane's top edge is always
        // exactly this wide and always exists. It meets the split view's own vertical divider at
        // the corner rather than overlapping it: the divider ends at this pane's leading edge and
        // this rule starts there.
        .overlay(alignment: .top) { Hairline() }
        .sheet(item: $signIn.request) { request in
            GitHubSignInSheet(request: request) { connected in
                signIn.finish(connected: connected)
            }
        }
        // Once, here, rather than a repository id threaded through every row of two lists that
        // have no other use for one. See `EnvironmentValues.openInRepoID`.
        .environment(\.openInRepoID, model.repo?.id)
    }

    private func pullRequestCard() -> WorkspaceHoverCard {
        WorkspaceHoverCard.pullRequestBand(
            workspace: model.workspace,
            pullRequest: model.pullRequest,
            localWork: model.localWork
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.inspectorTab {
        case .allFiles:
            FileTreeView(model: model)
        case .changes:
            ChangedFileList(model: model)
        case .checks:
            ChecksView(model: model)
        }
    }
}
