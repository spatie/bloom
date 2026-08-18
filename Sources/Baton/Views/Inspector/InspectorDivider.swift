import SwiftUI

/// The draggable boundary between the detail column and the inspector.
///
/// A named wrapper rather than a `PaneDivider` spelled out in `RootView`, because the bounds are
/// the inspector's own: the floor is what its header needs before its controls start dropping to
/// their narrow forms, and the ceiling leaves the transcript readable on a small display.
struct InspectorDivider: View {
    @Binding var width: Double

    /// The same bounds `HSplitView` was given.
    private static let bounds: ClosedRange<Double> = 280 ... 760

    var body: some View {
        PaneDivider(
            axis: .horizontal,
            length: $width,
            bounds: Self.bounds,
            reset: Double(Metrics.inspectorWidth),
            label: "Inspector width"
        )
    }
}
