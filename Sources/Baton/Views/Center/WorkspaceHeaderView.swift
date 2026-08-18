import SwiftUI

/// Kept as a compatibility boundary while the workspace chrome moves into the window toolbar.
/// A zero-height view lets callers migrate independently without leaving duplicate controls.
struct WorkspaceHeaderView: View {
    var model: WorkspaceModel

    var body: some View {
        EmptyView()
    }
}
