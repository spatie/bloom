import SwiftUI
import BloomCore

/// The boundary between two panes of the centre column: the line, a resize drag over the strip in
/// the middle of it, and a band either side of that strip that picks a pane up and moves it
/// elsewhere in the tab. Nothing is drawn for the move, so the pointer's shape is what says it is
/// there: an open hand outside the strip against the resize cursor inside it.
///
/// The gesture is on the divider rather than on the pane because a terminal pane is a SwiftTerm
/// `NSView` and a browser pane a `WKWebView`, and both want every mouse event for themselves.
///
/// It is a `DragGesture` rather than a `dropDestination`, and that was measured rather than argued.
/// `.dropDestination` installs an `NSView` drawn BEHIND the content it is applied to, a `WKWebView`
/// registers seventeen dragged types of its own and sits on top of it, and AppKit offers the drag
/// to the deepest registered destination, so over a browser pane the drop was never ours. Drawn
/// content wins where a drop destination cannot, because `NSHostingView` claims its own points
/// whatever a pane has registered.
///
/// `SplitPaneDivider` is the bottom panel's, where a split holds terminals and there is no tree to
/// move a pane in.
struct CenterPaneDivider: View {
    var axis: SplitAxis
    var ratio: Double
    /// How long the split is along its own axis, which turns a drag in points into a ratio.
    var span: Double
    /// How long the divider is, across that axis.
    var length: Double
    /// Where the line is, in the column's coordinate space, so a point from the drag can be read as
    /// an offset from it without the view having to measure itself.
    var line: CGRect
    /// The single pane on the leading or top side, and nil when that side is a group of panes
    /// rather than one: `SplitLayout.move` moves one pane, and a pane inside a group is reachable
    /// from the divider of its own parent split. See `SplitLayout.sides(at:)`.
    var first: String?
    /// The single pane on the trailing or bottom side, on the same terms.
    var second: String?
    var onResize: (Double) -> Void
    /// A pane being carried, with the pointer in the column's coordinate space.
    var onMoveChanged: (String, CGPoint) -> Void
    var onMoveEnded: (String, CGPoint) -> Void

    /// Where the ratio was when a resize started, so the drag follows the delta rather than
    /// reapplying the whole translation on every event.
    @State private var dragOrigin: Double?
    /// The pane this drag is carrying, decided from where the press landed and then held, so a
    /// pointer that crosses the line mid drag does not change what it picked up.
    @State private var carrying: String?
    /// Where the pointer is inside the band, or nil when it is not in it.
    @State private var pointer: CGPoint?

    /// Half the band, across the divider: the resize strip plus the seven points either side of it
    /// that pick a pane up. It cannot fall to `resizeReach`, because then the two gestures would
    /// want the same points and one of them would have to become a mode.
    private static let reach: CGFloat = 12
    /// Half the strip that resizes, which is the ten point grab `SplitPaneDivider` has always had.
    private static let resizeReach: CGFloat = 5
    /// One notch of the VoiceOver adjustable action, a twentieth of the split.
    private static let step: Double = 0.05

    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(
                width: axis == .horizontal ? Metrics.hairline : nil,
                height: axis == .vertical ? Metrics.hairline : nil
            )
            .frame(
                width: axis == .horizontal ? Self.reach * 2 : length,
                height: axis == .vertical ? Self.reach * 2 : length
            )
            // At rest the hit area is the ten point strip alone, so clicking a link or placing a
            // caret near a divider still reaches the page or the terminal. It grows to the full
            // band only while the pointer is in it, so stepping out to pick a pane up never leaves
            // the shape and the hover cannot switch off under the hand using it.
            .contentShape(band)
            .pointerStyle(pointerStyle)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): pointer = point
                case .ended: pointer = nil
                }
            }
            .gesture(drag)
            .onTapGesture(count: 2) { onResize(0.5) }
            .accessibilityElement()
            .accessibilityLabel(axis == .horizontal ? "Pane divider" : "Pane divider, stacked")
            .accessibilityValue(Text(ratio, format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                onResize(ratio + (direction == .increment ? Self.step : -Self.step))
            }
    }

    // MARK: - Where a point is

    /// How far a local point is from the line, negative on the leading or top side.
    private func across(of point: CGPoint?) -> CGFloat? {
        guard let point else { return nil }
        return (axis == .horizontal ? point.x : point.y) - Self.reach
    }

    /// Whether the outer band is part of the hit shape: the pointer is in the divider already, and
    /// a side holds a single pane for a press out there to pick up. Not while one is being carried,
    /// when the pointer has left and the plate and the wash say what is happening.
    private var isOfferingMove: Bool {
        pointer != nil && carrying == nil && (first != nil || second != nil)
    }

    /// The resize strip at rest, and the whole band while the pointer is in it.
    private var band: some Shape {
        let half = isOfferingMove ? Self.reach : Self.resizeReach
        var path = Path()
        path.addRect(axis == .horizontal
            ? CGRect(x: Self.reach - half, y: 0, width: half * 2, height: length)
            : CGRect(x: 0, y: Self.reach - half, width: length, height: half * 2))
        return path
    }

    /// Which pane a press at this point would pick up, and nil for a press that resizes instead.
    private func pane(at point: CGPoint) -> String? {
        guard let across = across(of: point), abs(across) > Self.resizeReach else { return nil }
        return across < 0 ? first : second
    }

    /// The open hand over the band and the resize cursor over the strip. With nothing drawn on the
    /// divider, this is the whole of what says the two are different grabs.
    private var pointerStyle: PointerStyle? {
        guard let pointer else { return nil }
        if pane(at: pointer) != nil { return .grabIdle }
        return axis == .horizontal ? .columnResize : .rowResize
    }

    // MARK: - The drag

    /// One gesture for both jobs, because they are one press in one view.
    ///
    /// `.named` rather than `.local`, and load bearing for the reason `SplitPaneDivider` uses
    /// `.global`: this view moves the moment the ratio changes, so a translation measured from an
    /// origin the translation itself moved oscillates instead of following.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(CenterPanesView.space))
            .onChanged { value in
                if dragOrigin == nil, carrying == nil {
                    carrying = pane(at: local(value.startLocation))
                    if carrying == nil {
                        dragOrigin = ratio
                        // A transcript in either half holds still until this ends. AppKit calls no
                        // live resize for a SwiftUI drag, so saying so is the only way it knows.
                        // See `TranscriptHoldView`.
                        NotificationCenter.default.post(name: .bloomPaneResizeBegan, object: nil)
                    }
                }
                if let carrying {
                    return onMoveChanged(carrying, value.location)
                }
                guard span > 0, let origin = dragOrigin else { return }
                let travelled = axis == .horizontal
                    ? value.translation.width
                    : value.translation.height
                onResize(origin + Double(travelled) / span)
            }
            .onEnded { value in
                if let carrying { onMoveEnded(carrying, value.location) }
                if dragOrigin != nil {
                    NotificationCenter.default.post(name: .bloomPaneResizeEnded, object: nil)
                }
                carrying = nil
                dragOrigin = nil
            }
    }

    /// A point in the column's space, as an offset inside this view.
    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - line.midX + Self.reach,
            y: point.y - line.midY + (axis == .horizontal ? length / 2 : Self.reach)
        )
    }
}
