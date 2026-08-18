import SwiftUI
import BatonCore

/// The right hand column: what the agent changed, and what GitHub thinks of it.
///
/// Everything here is a thin arrangement of the pieces below it: the pull request strip, the tab
/// row, and whichever pane the tab row selected.
struct InspectorView: View {
    let model: WorkspaceModel

    /// Review mode belongs to the column rather than to a file, so it survives switching files.
    @State private var isReviewing = false

    var body: some View {
        VStack(spacing: 0) {
            PullRequestBar(model: model)
            Hairline()
            InspectorToolbar(model: model, isReviewing: $isReviewing)
            Hairline()
            content
        }
        .background(Palette.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch model.inspectorTab {
        case .allFiles:
            FileTreeView(model: model)
        case .changes:
            changes
        case .checks:
            ChecksView(model: model)
        }
    }

    @ViewBuilder
    private var changes: some View {
        if isReviewing, let file = model.selectedFile ?? model.changedFiles.first {
            InspectorReviewPane(model: model, file: file)
        } else {
            VSplitLayout(
                top: { ChangedFileList(model: model) },
                bottom: {
                    if let file = model.selectedFile {
                        DiffView(model: model, file: file)
                    }
                },
                hasBottom: model.selectedFile != nil
            )
        }
    }
}
