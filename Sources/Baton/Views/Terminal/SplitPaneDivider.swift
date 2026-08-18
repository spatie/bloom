import SwiftUI
import AppKit
import BatonCore

/// The draggable boundary between two terminal panes.
///
/// A near twin of the inspector's `PaneDivider`, and deliberately not a reuse of it: that one
/// carries a length in points and is laid out by the stack it sits in, while this one carries a
/// ratio and is positioned by the split tree. What is worth copying is the feel, which is the
/// hairline inside a grab strip, the cursor pushed on hover, the double click reset and the
/// adjustable action.
///
/// The strip overlaps the panes either side rather than reserving space of its own. A gap wide
/// enough to aim at is a gap wide enough to see, and no terminal on this platform draws one.
struct SplitPaneDivider: View {
    var axis: SplitAxis
    var ratio: Double
    /// How long the split is along its own axis, which is what turns a drag in points into a
    /// change in ratio.
    var span: Double
    /// How long the divider itself is, across that axis.
    var length: Double
    var color: Color
    var onChange: (Double) -> Void

    /// Where the ratio was when the drag started. Without it the divider would chase the pointer
    /// by the whole translation on every event rather than by the delta.
    @State private var dragOrigin: Double?

    private static let grab: CGFloat = 10
    /// One notch of the VoiceOver adjustable action, a twentieth of the split.
    private static let step: Double = 0.05

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(
                width: axis == .horizontal ? Metrics.hairline : nil,
                height: axis == .vertical ? Metrics.hairline : nil
            )
            .frame(
                width: axis == .horizontal ? Self.grab : length,
                height: axis == .vertical ? Self.grab : length
            )
            .contentShape(Rectangle())
            .onHover { inside in
                // Pushed and popped rather than `set`, so the arrow comes back when the pointer
                // leaves. During a drag AppKit keeps the pushed cursor, which is what we want.
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // `.global`, and that is the whole of why this drag is smooth. The default is
                // `.local`, which is local to THIS view, and this view moves the moment the ratio
                // changes. Measuring a translation from an origin the translation itself just
                // moved is a feedback loop, and the divider oscillates instead of following.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        guard span > 0 else { return }
                        let origin = dragOrigin ?? ratio
                        if dragOrigin == nil { dragOrigin = origin }
                        let travelled = axis == .horizontal
                            ? drag.translation.width
                            : drag.translation.height
                        onChange(origin + Double(travelled) / span)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .onTapGesture(count: 2) { onChange(0.5) }
            .accessibilityElement()
            .accessibilityLabel(axis == .horizontal ? "Pane divider" : "Pane divider, stacked")
            .accessibilityValue(Text(ratio, format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                onChange(ratio + (direction == .increment ? Self.step : -Self.step))
            }
    }
}
