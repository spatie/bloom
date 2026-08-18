import SwiftUI

/// A list above and a detail below, with a boundary the reader can move.
///
/// The list used to be pinned at a fixed height, which meant that however tall the window was you
/// saw the same eight rows of it and everything else went to the diff. It is the one edge in this
/// column that was not draggable, next to two that are, and a fixed pane between two adjustable
/// ones is the thing that makes a window feel unfinished.
///
/// The stored number is the LIST's height, not the detail's, so growing the window grows the diff
/// and leaves the list where the reader put it. `PaneDivider` sizes the pane after itself, which
/// is the opposite, so the binding it is handed is projected: what is stored is what survives, and
/// what the divider drags is whatever the column has left.
struct VSplitLayout<Top: View, Bottom: View>: View {
    // The built views rather than the builders. Storing an escaping `@ViewBuilder` closure on a
    // view keeps it alive across updates for no benefit; the synthesized initializer still takes
    // the trailing closures at the call site.
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom
    var hasBottom: Bool

    /// Shared by the changed file list and the worktree tree on purpose: they are the same pane
    /// wearing two tabs, and a boundary that jumped when you switched tab would be a bug.
    @AppStorage("inspector.listHeight") private var listHeight = Double(InspectorLayout.listHeight)

    /// What the column has to divide. Measured, because the floor under the detail is whatever
    /// still leaves the list usable and only the window knows how much that is.
    @State private var columnHeight: Double = 0

    /// A few rows above, and enough below for a hunk header and some lines under it.
    private static var minimumList: Double { Double(3 * Metrics.rowHeight) }
    private static var minimumDetail: Double { 120 }

    private var detailBounds: ClosedRange<Double> {
        let ceiling = max(Self.minimumDetail, columnHeight - Self.minimumList)
        return Self.minimumDetail ... ceiling
    }

    /// The list, kept inside what the window can currently give it.
    private var currentList: Double {
        guard columnHeight > 0 else { return listHeight }
        return columnHeight - (columnHeight - listHeight).clamped(to: detailBounds)
    }

    /// What the divider drags: the detail's height, derived from the list's and written back as
    /// the list's, so the stored value keeps its meaning.
    private var detailHeight: Binding<Double> {
        Binding(
            get: { columnHeight - currentList },
            set: { listHeight = columnHeight - $0.clamped(to: detailBounds) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasBottom {
                top.frame(height: currentList)
                    .frame(maxWidth: .infinity)
                PaneDivider(
                    axis: .vertical,
                    length: detailHeight,
                    bounds: detailBounds,
                    reset: columnHeight - Double(InspectorLayout.listHeight),
                    label: "File list height"
                )
                bottom.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                top.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { columnHeight = $0 }
    }
}
