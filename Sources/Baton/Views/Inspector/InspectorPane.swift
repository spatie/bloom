import SwiftUI

/// The inspector column's stable root.
///
/// Structural stability is the whole point of this type. When the inspector's content was written
/// inline as `if let model { InspectorView(...).inspectorColumnWidth(...) }`, the column width
/// modifier itself came and went as the selection resolved, so AppKit kept adding and removing the
/// column's constraints and recreating the hosted platform view. That is an unbounded Update
/// Constraints loop, and it crashed the window. Here the pane is always the same view, the width
/// is always applied, and only what is drawn inside changes.
///
/// `StableColumn` is part of the same defence, and it is not decoration: without it, showing and
/// hiding the inspector twice crashed the window with the same Update Constraints loop. See that
/// type for why.
struct InspectorPane: View {
    let model: WorkspaceModel?

    var body: some View {
        StableColumn(idealWidth: Metrics.inspectorWidth) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            InspectorView(model: model)
                // Rebuilt per workspace, so a diff selection never leaks across a switch.
                .id(model.workspace.id)
        } else {
            EmptyStateView(
                glyph: "sidebar.right",
                title: "No workspace selected",
                message: "Pick a workspace to see what its agent changed."
            )
        }
    }
}
