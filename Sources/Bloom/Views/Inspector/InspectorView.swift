import SwiftUI
import BloomCore

/// The right hand column: what the agent changed, and what GitHub thinks of it.
///
/// Everything here is a thin arrangement of the pieces below it: the tab row, and whichever pane
/// the tab row selected. The pull request strip is above the column rather than in it, in the
/// title bar, at the width this pane happens to be. See `TitleBarStrip`.
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
        // The pull request strip used to be the first row here. It is in the title bar now, as
        // wide as this pane and directly above it, so the column starts at its tab row. See
        // `TitleBarStrip`.
        VStack(spacing: 0) {
            InspectorToolbar(model: model)
            Hairline()
            content
        }
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
