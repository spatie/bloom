import SwiftUI

/// The draggable boundary between the detail column and the inspector.
///
/// A named wrapper rather than a `PaneDivider` spelled out in `RootView`, because the bounds are
/// the inspector's own: the floor is what its header needs before its controls start dropping to
/// their narrow forms, and the ceiling leaves the transcript readable on a small display.
struct InspectorDivider: View {
    @Binding var width: Double

    /// How much room the detail column has, so the ceiling can be what actually fits rather than
    /// a fixed number. Zero until the first layout, which is why `bounds` falls back.
    var available: Double = 0

    /// The floor is what the inspector's header needs before its controls drop to their narrow
    /// forms. The ceiling is a readable transcript, or whatever is left, whichever is smaller.
    static let minimum: Double = 280
    private static let preferredMaximum: Double = 760

    /// Never wider than the space left after the detail column keeps its own minimum.
    ///
    /// Without this the inspector took a fixed width the detail column could not give up, so
    /// `NavigationSplitView` made room by squeezing the SIDEBAR instead: dragging this divider
    /// pushed Home and Search out of the window.
    private var bounds: ClosedRange<Double> {
        guard available > 0 else { return Self.minimum ... Self.preferredMaximum }
        let ceiling = available - DetailColumnLayout.minimum - Metrics.spacingWide
        return Self.minimum ... max(Self.minimum, min(Self.preferredMaximum, ceiling))
    }

    var body: some View {
        PaneDivider(
            axis: .horizontal,
            length: $width,
            bounds: bounds,
            reset: Double(Metrics.inspectorWidth),
            label: "Inspector width"
        )
    }
}
