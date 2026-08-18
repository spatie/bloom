import SwiftUI
import BatonCore

/// The centre column's panes, laid out from the split tree.
///
/// Positioned absolutely from the frames the tree computes rather than by nesting stacks the way
/// the tree nests, for the same two reasons the terminal does it: a nested layout would have to be
/// built out of `AnyView` because the view type would be recursive, and every reshape would move a
/// live transcript, web view or shell into a different superview. Flat means a pane keeps its place
/// in the hierarchy however the tree is rearranged around it.
struct CenterPanesView: View {
    @Bindable var model: WorkspaceModel

    private var panes: CenterPaneStore { .shared }

    /// What a split takes out of the space its two panes share. One point, because the strip the
    /// pointer aims at is drawn over the panes rather than reserved between them.
    private static let dividerThickness: Double = 1

    var body: some View {
        // Read here rather than inside the `GeometryReader`, so the dependency on the store is
        // registered while this body is being tracked. A read that only happens in the layout pass
        // is a redraw that only happens by luck.
        let layout = panes.layout(for: model.workspace.id)

        return GeometryReader { proxy in
            let geometry = layout.geometry(in: proxy.size, dividerThickness: Self.dividerThickness)

            ZStack(alignment: .topLeading) {
                if proxy.size.width > 1, proxy.size.height > 1 {
                    ForEach(geometry.panes, id: \.pane) { item in
                        CenterPaneView(
                            model: model,
                            pane: item.pane,
                            isFocused: layout.focus == item.pane,
                            isSplit: layout.paneCount > 1
                        )
                        .frame(width: item.frame.width, height: item.frame.height)
                        // A pane whose content cannot fit the width it was given keeps the
                        // overflow to itself. Without this a composer wider than half the column
                        // draws over the pane beside it, and the two conversations bleed together.
                        .clipped()
                        .position(x: item.frame.midX, y: item.frame.midY)
                    }

                    ForEach(geometry.dividers, id: \.path) { divider in
                        SplitPaneDivider(
                            axis: divider.axis,
                            ratio: divider.ratio,
                            span: divider.span,
                            length: divider.axis == .horizontal
                                ? divider.frame.height
                                : divider.frame.width,
                            color: Palette.border
                        ) { ratio in
                            panes.setRatio(ratio, at: divider.path, in: model.workspace.id)
                        }
                        .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                }
            }
        }
        .background(Palette.windowBackground)
    }
}
