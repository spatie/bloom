import SwiftUI
import BloomCore

/// The right hand column: what the agent changed, and what GitHub thinks of it.
///
/// Everything here is a thin arrangement of the pieces below it: the column's own top edge, what
/// the pull request strip has to say, the tab row, and whichever pane the tab row selected. The
/// strip itself is above the column rather than in it, in the title bar, at the width this pane
/// happens to be. See `TitleBarStrip`.
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

    var body: some View {
        VStack(spacing: 0) {
            // The column's own top edge.
            //
            // The pane is white and the band above it is the title bar, so without a rule the
            // white simply begins. Every other boundary in this window is a `Hairline` in
            // `Palette.border`, and this is the same rule at the same weight rather than a sixth
            // kind of line.
            //
            // Drawn here rather than under the title bar strip, and never in both places. The
            // strip is only as wide as this pane and is not there at all on a workspace with no
            // inspector, so a rule belonging to it would be a line that comes and goes; the pane's
            // top edge is always exactly this wide and always exists. It meets the split view's
            // own vertical divider at the corner rather than overlapping it: the divider ends at
            // this pane's leading edge and this rule starts there.
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

            InspectorToolbar(model: model)
            Hairline()
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
        .sheet(item: $signIn.request) { request in
            GitHubSignInSheet(request: request) { connected in
                signIn.finish(connected: connected)
            }
        }
        // Once, here, rather than a repository id threaded through every row of two lists that
        // have no other use for one. See `EnvironmentValues.openInRepoID`.
        .environment(\.openInRepoID, model.repo?.id)
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
