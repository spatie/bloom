import SwiftUI
import AppKit

/// The draggable boundary between two panes, either between two columns or between two rows.
///
/// This exists because neither `HSplitView` nor `VSplitView` can be used here. Their dividers are
/// drawn by AppKit down the whole bounds of the split view, and under a unified toolbar the detail
/// column runs underneath the title bar, so the rule came up through the toolbar and crossed the
/// window title. A divider laid out as an ordinary view sits in the same safe area as the panes
/// either side of it, which is where a pane boundary belongs.
///
/// The hairline is one pixel, but the grab area is not: a one pixel target is a target you have to
/// aim at. The strip is `Metrics.spacingWide` across with the rule drawn down its middle, which is
/// roughly what AppKit gives a split view divider.
///
/// One type for both axes rather than two near-identical ones, because the cursor, the drag origin,
/// the clamping, the double click reset and the adjustable action are the whole of the behaviour
/// and none of it differs by axis.
struct PaneDivider: View {
    /// The axis the drag runs along: `.horizontal` sizes a column, `.vertical` sizes a row. The
    /// rule itself is drawn across it.
    var axis: Axis

    /// The size of the pane that lies AFTER the divider, which is the only arrangement either call
    /// site has. That is what lets one subtraction serve both: dragging towards the pane's own edge
    /// (left, or up) grows it, so the translation always comes off the starting size.
    @Binding var length: Double

    /// How far the pane may be dragged. Passed in rather than fixed here because the ceiling on a
    /// row is whatever leaves the pane above it usable, which only the parent has measured.
    var bounds: ClosedRange<Double>

    /// Where a double click puts it back to.
    var reset: Double

    var label: String

    /// Where the pane was when the current drag started. Without it the pane would chase the
    /// pointer by the whole translation on every event rather than by the delta.
    @State private var dragOrigin: Double?

    /// One notch of the VoiceOver adjustable action, big enough to be worth a gesture.
    private static let step: Double = 24

    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(
                width: axis == .horizontal ? Metrics.hairline : nil,
                height: axis == .vertical ? Metrics.hairline : nil
            )
            .frame(
                width: axis == .horizontal ? Metrics.spacingWide : nil,
                height: axis == .vertical ? Metrics.spacingWide : nil
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
                // `.local`, which is local to THIS view, and this view moves the moment `length`
                // changes. Measuring a translation from an origin that the translation itself
                // just moved is a feedback loop: the divider oscillated between the two ends of
                // its bounds instead of following the pointer.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let origin = dragOrigin ?? length
                        if dragOrigin == nil { dragOrigin = origin }
                        let travelled = axis == .horizontal
                            ? drag.translation.width
                            : drag.translation.height
                        length = (origin - Double(travelled)).clamped(to: bounds)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            // A double click resets, the same escape hatch the composer's divider offers.
            .onTapGesture(count: 2) { length = reset.clamped(to: bounds) }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? Self.step : -Self.step
                length = (length + step).clamped(to: bounds)
            }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
