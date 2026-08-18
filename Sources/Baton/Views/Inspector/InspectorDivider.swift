import SwiftUI
import AppKit

/// The draggable boundary between the detail column and the inspector.
///
/// This exists because `HSplitView` cannot be used here. Its divider is drawn by AppKit down the
/// whole bounds of the split view, and under a unified toolbar the detail column runs underneath
/// the title bar, so the rule came up through the toolbar and crossed the window title. A divider
/// laid out as an ordinary view sits in the same safe area as the panes either side of it, which
/// is where a pane boundary belongs.
///
/// The hairline is one pixel, but the grab area is not: a one pixel target is a target you have to
/// aim at. The strip is `Metrics.spacingWide` wide with the rule drawn down its middle, which is
/// roughly what AppKit gives a split view divider.
struct InspectorDivider: View {
    @Binding var width: Double

    /// Where the inspector was when the current drag started. Without it the pane would chase the
    /// pointer by the whole translation on every event rather than by the delta.
    @State private var dragOrigin: Double?

    /// The same bounds `HSplitView` was given. The floor is what the inspector's own header needs
    /// before its controls start dropping to their narrow forms, and the ceiling leaves the
    /// transcript readable on a small display.
    private static let minimum: Double = 280
    private static let maximum: Double = 760

    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(width: Metrics.hairline)
            .frame(width: Metrics.spacingWide)
            .contentShape(Rectangle())
            .onHover { inside in
                // Pushed and popped rather than `set`, so the arrow comes back when the pointer
                // leaves. During a drag AppKit keeps the pushed cursor, which is what we want.
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let origin = dragOrigin ?? width
                        if dragOrigin == nil { dragOrigin = origin }
                        // Dragging left widens the inspector, so the translation is subtracted.
                        width = (origin - value.translation.width)
                            .clamped(to: Self.minimum ... Self.maximum)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            // A double click resets, the same escape hatch the composer's divider offers.
            .onTapGesture(count: 2) { width = Metrics.inspectorWidth }
            .accessibilityElement()
            .accessibilityLabel("Inspector width")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 24 : -24
                width = (width + step).clamped(to: Self.minimum ... Self.maximum)
            }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
