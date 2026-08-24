import SwiftUI
import BloomCore

/// The boundary between two panes of the centre column: the line, the resize drag, and the grips
/// by which either of the two panes is picked up and moved somewhere else in the tab.
///
/// # Why the pane move starts here, and not on the pane
///
/// A pane is not something the pointer can grab. A terminal pane is a SwiftTerm `NSView` that wants
/// every mouse event for selecting text and a browser pane is a `WKWebView` that wants them for the
/// page, so "press anywhere in the pane and drag" takes a gesture away from the two kinds of
/// content this app is mostly made of. A modifier held down while dragging dodges that and is what
/// the first design reached for, but nothing on screen says it exists.
///
/// A divider is the one surface inside a split tab that belongs to Bloom rather than to what a pane
/// is showing, and it is exactly as available as the gesture is useful: **a divider only exists
/// once a tab has been split, which is the only time there is anywhere to move a pane to.** Every
/// pane of a split tree is a leaf and so the direct child of some split, so every pane has a
/// divider against it and can be reached. Nothing is added to a pane at rest.
///
/// # Why this is a `DragGesture` and not `dropDestination`
///
/// It was `dropDestination` first, and it could not work, which was measured rather than argued.
/// `.dropDestination` installs a real `NSView` as a sibling drawn BEHIND the content it is applied
/// to, and a `WKWebView` registers seventeen dragged types of its own and sits on top of it:
/// `hitTest` in the middle of a browser pane returns the web view, and AppKit offers the drag to
/// the deepest registered destination, which is therefore never ours. The same measurement says the
/// opposite about drawn content: a SwiftUI view declared over a web view DOES win the hit test on
/// its own area, because `NSHostingView` claims those points itself.
///
/// So a gesture on drawn content reaches the pointer where a drop destination cannot, and nothing
/// a pane happens to register can take it away. Nothing is lost by leaving the pasteboard out of
/// it either: a pane move never leaves the window, so there was never anything to carry.
///
/// # Why it is not `SplitPaneDivider`
///
/// That one is the bottom panel's, where a split holds terminals and there is no tree to move a
/// pane in. It stays exactly as it is rather than growing a second job and a pile of optional
/// arguments for a caller that has no use for them.
struct CenterPaneDivider: View {
    var axis: SplitAxis
    var ratio: Double
    /// How long the split is along its own axis, which is what turns a drag in points into a
    /// change in ratio.
    var span: Double
    /// How long the divider is, across that axis.
    var length: Double
    /// Where the line itself is, in the column's coordinate space, so a point from the drag can be
    /// read as an offset from the line without the view having to measure itself.
    var line: CGRect
    /// The single pane on the leading or top side, and nil when that side is a group of panes
    /// rather than one. A group has no grip: `SplitLayout.move` moves one pane, and every pane is
    /// reachable from the divider of its own parent split anyway. See `SplitLayout.sides(at:)`.
    var first: String?
    /// The single pane on the trailing or bottom side, on the same terms.
    var second: String?
    var onResize: (Double) -> Void
    /// A pane being carried, with the pointer in the column's coordinate space.
    var onMoveChanged: (String, CGPoint) -> Void
    var onMoveEnded: (String, CGPoint) -> Void

    /// Where the ratio was when a resize started. Without it the divider would chase the pointer by
    /// the whole translation on every event rather than by the delta.
    @State private var dragOrigin: Double?
    /// The pane this drag is carrying, decided from where the press landed and then held for the
    /// rest of the gesture. Read on every change, so a pointer that wanders across the line
    /// mid drag does not change its mind about what it picked up.
    @State private var carrying: String?
    /// Where the pointer is inside the band, or nil when it is not in it. Drives the grips, and
    /// the pointer's own shape.
    @State private var pointer: CGPoint?

    /// Half the band the view occupies, across the divider. Wide enough to hold a grip outside the
    /// resize strip.
    private static let reach: CGFloat = 12
    /// Half the strip that resizes, which is the ten point grab `SplitPaneDivider` has always had.
    /// A press inside this is a resize and a press outside it is a move, so neither is a mode and
    /// both are aimed at rather than remembered.
    private static let resizeReach: CGFloat = 5
    /// One grip, along the divider and across it. It sits outside the resize strip, so the two
    /// never overlap and a press means one thing.
    private static let gripLength: CGFloat = 22
    private static let gripBreadth: CGFloat = 7
    /// One notch of the VoiceOver adjustable action, a twentieth of the split.
    private static let step: Double = 0.05

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Palette.border)
                .frame(
                    width: axis == .horizontal ? Metrics.hairline : nil,
                    height: axis == .vertical ? Metrics.hairline : nil
                )

            if isShowingGrips {
                grip(first, side: -1)
                grip(second, side: 1)
            }
        }
        .frame(
            width: axis == .horizontal ? Self.reach * 2 : length,
            height: axis == .vertical ? Self.reach * 2 : length
        )
        // The hit area, and the whole reason the grips can be bigger than the strip without taking
        // a band of every pane away from the content in it.
        //
        // At rest this is the ten point strip and nothing else, so clicking a link or placing a
        // caret near a divider reaches the page or the terminal exactly as it did before. While the
        // pointer is in it the shape GROWS to include the two grips, so moving from the strip onto
        // a grip never leaves the shape and the grips cannot flicker. That flicker is why the first
        // attempt drew a permanent mark instead: it had the grips owning their own hover, drawn on
        // top of a divider that reported it had been left the moment the pointer reached them. One
        // shape has no such problem.
        //
        // Ghostty solves it the same way, which is visible in the recording rather than guessed at:
        // its mark is drawn while the pointer is twelve points below the divider and a hundred and
        // forty points away along it, and gone with the pointer sixty points below. The region it
        // watches is bigger than the mark it draws.
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

    // MARK: - The grips

    /// Shown while the pointer is in the band and nothing is being carried yet.
    ///
    /// They go the moment a drag begins, because from then on the plate under the pointer and the
    /// wash on the pane are what say what is happening, and a grip left behind at the divider is a
    /// mark for a gesture that has already started. It would also have nowhere to be: the pointer
    /// leaves the band immediately, and the grip would spring back to the middle of the divider.
    private var isShowingGrips: Bool {
        pointer != nil && carrying == nil && (first != nil || second != nil)
    }

    /// Beside the pointer rather than at the middle of the divider, which is the one place this
    /// goes past the reference. Ghostty keeps its mark at the midpoint, which is fine for the short
    /// horizontal divider in the recording and a long way from the hand on a full height vertical
    /// one, which is the split the owner actually has.
    private var alongPointer: CGFloat {
        guard let pointer else { return length / 2 }
        let raw = axis == .horizontal ? pointer.y : pointer.x
        // Kept whole inside the divider, so a grip never hangs off either end.
        return min(max(raw, Self.gripLength / 2), max(Self.gripLength / 2, length - Self.gripLength / 2))
    }

    /// `side` is -1 for the leading or top pane and 1 for the trailing or bottom one.
    @ViewBuilder
    private func grip(_ pane: String?, side: CGFloat) -> some View {
        if pane != nil {
            let across = side * (Self.resizeReach + Self.gripBreadth / 2)
            RoundedRectangle(cornerRadius: Metrics.cornerSmall / 2, style: .continuous)
                .fill(Palette.textSecondary.opacity(isOver(side: side) ? 0.7 : 0.3))
                .frame(
                    width: axis == .horizontal ? Self.gripBreadth : Self.gripLength,
                    height: axis == .horizontal ? Self.gripLength : Self.gripBreadth
                )
                .offset(
                    x: axis == .horizontal ? across : alongPointer - length / 2,
                    y: axis == .horizontal ? alongPointer - length / 2 : across
                )
                .allowsHitTesting(false)
        }
    }

    private func isOver(side: CGFloat) -> Bool {
        guard let across = across(of: pointer) else { return false }
        return abs(across) > Self.resizeReach && (across < 0 ? side < 0 : side > 0)
    }

    // MARK: - Where a point is

    /// How far a local point is from the line, negative on the leading or top side.
    private func across(of point: CGPoint?) -> CGFloat? {
        guard let point else { return nil }
        return (axis == .horizontal ? point.x : point.y) - Self.reach
    }

    /// The hit area: the resize strip at rest, and the strip plus the two grips while the pointer
    /// is in it.
    private var band: some Shape {
        var path = Path()
        let strip = axis == .horizontal
            ? CGRect(x: Self.reach - Self.resizeReach, y: 0, width: Self.resizeReach * 2, height: length)
            : CGRect(x: 0, y: Self.reach - Self.resizeReach, width: length, height: Self.resizeReach * 2)
        path.addRect(strip)

        if isShowingGrips {
            for (pane, side) in [(first, CGFloat(-1)), (second, CGFloat(1))] where pane != nil {
                path.addRect(gripRect(side: side))
            }
        }
        return path
    }

    private func gripRect(side: CGFloat) -> CGRect {
        let inner = Self.reach + side * Self.resizeReach
        let outer = inner + side * Self.gripBreadth
        let along = alongPointer
        if axis == .horizontal {
            return CGRect(
                x: min(inner, outer), y: along - Self.gripLength / 2,
                width: Self.gripBreadth, height: Self.gripLength
            )
        }
        return CGRect(
            x: along - Self.gripLength / 2, y: min(inner, outer),
            width: Self.gripLength, height: Self.gripBreadth
        )
    }

    /// Which pane a press at this point would pick up, and nil for a press that resizes instead.
    private func pane(at point: CGPoint) -> String? {
        guard let across = across(of: point), abs(across) > Self.resizeReach else { return nil }
        return across < 0 ? first : second
    }

    /// The resize cursor over the strip and the open hand over a grip, so the affordance is legible
    /// before anything is pressed. One style for the whole view, chosen from where the pointer is,
    /// rather than three views each with their own: three views would mean three hover regions
    /// trading one flag between them, which is the flicker `contentShape` exists here to avoid.
    private var pointerStyle: PointerStyle? {
        guard let pointer else { return nil }
        if pane(at: pointer) != nil { return .grabIdle }
        return axis == .horizontal ? .columnResize : .rowResize
    }

    // MARK: - The drag

    /// One gesture for both jobs, because they are one press in one view. What it turns out to be
    /// is decided from where the press landed and then held for the rest of it, so a pointer that
    /// crosses the line halfway through a move does not change what it is carrying.
    ///
    /// `.named` rather than `.local`, and that is load bearing for the same reason
    /// `SplitPaneDivider` uses `.global`: this view MOVES the moment the ratio changes, so measuring
    /// a translation from an origin the translation itself just moved is a feedback loop, and the
    /// divider oscillates instead of following. The column's own space does not move.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(CenterPanesView.space))
            .onChanged { value in
                if dragOrigin == nil, carrying == nil {
                    carrying = pane(at: local(value.startLocation))
                    if carrying == nil { dragOrigin = ratio }
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
