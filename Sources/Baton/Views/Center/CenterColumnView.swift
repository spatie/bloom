import SwiftUI
import BatonCore

/// The centre column: the workspace's tabs, and the panes they are shown in.
///
/// One view for every kind of tab, where there used to be two that each drew their own copy of the
/// strip and swapped places as the selection changed. That swap is what made every hop between a
/// conversation and a terminal rebuild the column and re-run the workspace's arrival work, and it
/// is also what made a chat and a terminal mutually exclusive. A pane holds a tab, so now they are
/// not.
struct CenterColumnView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            SessionTabsView(model: model)
            CenterPanesView(model: model)
        }
        .background(Palette.windowBackground)
        .task(id: model.workspace.id) { await model.onAppear() }
    }
}
