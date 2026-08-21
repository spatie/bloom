import SwiftUI
import BloomCore

/// The two grips at the middle of a divider, one for each pane it separates, by which a pane is
/// picked up and moved somewhere else in the tab.
///
/// # Why the affordance is here and not on the pane
///
/// A pane is not something the pointer can grab. A terminal pane is a SwiftTerm `NSView` that
/// wants every mouse event for selecting text, and a browser pane is a `WKWebView` that wants
/// them for the page, so "press anywhere in the pane and drag" would take a gesture away from
/// the two kinds of content this app is mostly made of. A modifier held down while dragging
/// would dodge that, and it is what the first design reached for, but it is a thing nobody can
/// find: there is nothing on screen that says it exists.
///
/// A divider is the one surface inside a split tab that belongs to Bloom rather than to what a
/// pane is showing, and it is exactly as available as the gesture is useful: **a divider only
/// exists once a tab has been split, which is the only time there is anywhere to move a pane
/// to.** Every pane of a split tree is a child of some split, so every pane has a divider
/// against it and can be reached. Nothing is added to a pane at rest, which matters, because the
/// coloured bar that used to mark the focused pane was taken out for being ugly and this must
/// not put it back in another form.
///
/// Ghostty answers the same question the same way, which is where the shape came from: measured
/// off a screen recording of it, a small mark appears at the middle of the divider under the
/// pointer (present in one frame, absent in another with the pointer elsewhere, so it is
/// revealed by hover rather than always drawn), the cursor becomes the open hand over it, and
/// dragging from it carries a small floating rectangle while the half of the window the pane
/// would land in is washed with a tint.
///
/// # Why there are two grips rather than one
///
/// A divider has a pane on each side and one mark in the middle of it cannot say which of them
/// it would pick up. Ghostty's answer appears to be a fixed convention, and a convention that has
/// to be learned by trying it is a poor one for a gesture that rearranges the window. So there is
/// a grip on each side of the line, each drawn inside the pane it moves and each highlighting on
/// its own hover, and the question answers itself before the mouse goes down.
struct PaneGrabHandle: View {
    /// Which way the two panes are arranged, which is what turns the pair of grips.
    var axis: SplitAxis
    /// The single pane on the leading or top side of this divider, and nil when that side is a
    /// group of panes rather than one. A group has no grip: `SplitLayout.move` moves one pane, and
    /// every pane is reachable from the divider of its own parent split anyway. See
    /// `SplitLayout.sides(at:)`.
    var first: String?
    /// The single pane on the trailing or bottom side, on the same terms.
    var second: String?
    /// Told which pane the pointer is over, so the pane itself can say so. Nil when neither.
    var onPointerOver: (String?) -> Void

    /// The long side of one grip. Short enough to leave most of the divider free to be dragged as
    /// a divider, long enough to be a target rather than a pixel.
    private static let length: CGFloat = 22
    /// The short side of one grip, and therefore how much of each pane the pair reaches into.
    private static let breadth: CGFloat = 7
    /// The gap the divider's own hairline runs down, which is what makes the pair read as two
    /// grips against a line rather than as one mark with a scratch through it.
    private static let gap: CGFloat = 3

    /// Along the divider for a stacked split, across it for a side by side one, so the pair always
    /// sits with one grip in each pane.
    @ViewBuilder
    var body: some View {
        if axis == .horizontal {
            HStack(spacing: Self.gap) { grip(first); grip(second) }
        } else {
            VStack(spacing: Self.gap) { grip(first); grip(second) }
        }
    }

    /// A side with no single pane still takes its place in the row, so the pair stays centred on
    /// the divider and one lone grip does not slide across to sit on the line.
    @ViewBuilder
    private func grip(_ pane: String?) -> some View {
        let width = axis == .horizontal ? Self.breadth : Self.length
        let height = axis == .horizontal ? Self.length : Self.breadth

        if let pane {
            PaneGrip(pane: pane, width: width, height: height, onPointerOver: onPointerOver)
        } else {
            Color.clear.frame(width: width, height: height).allowsHitTesting(false)
        }
    }
}

/// One grip: the part that is actually dragged, and the only part that knows a pane's name.
///
/// Its own view because the hover has to be its own. Two grips sharing one hover flag would each
/// light up when the other was pointed at, and the whole reason there are two of them is to say
/// which pane is about to be picked up.
private struct PaneGrip: View {
    var pane: String
    var width: CGFloat
    var height: CGFloat
    var onPointerOver: (String?) -> Void

    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.cornerSmall / 2, style: .continuous)
            .fill(Palette.textSecondary.opacity(isHovered ? 0.55 : 0.18))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            // The payload says it is a pane, because a tab's id and a pane's id can be the same
            // string: an unsplit tab's only pane carries the id of the content at its root, and
            // splitting that tab leaves the pane carrying it. See `PaneDrop`.
            .draggable(PaneDrop.pane(pane).encoded)
            // The open hand, which is the one pointer on this platform that means "this is yours to
            // pick up and put somewhere".
            //
            // `pointerStyle` rather than `NSCursor.openHand.push()`, and that is not a preference.
            // The grip is drawn over the divider, which pushes a resize cursor of its own on hover
            // and pops it on exit. Two views each pushing onto one global cursor stack means the
            // answer depends on which of the two hover callbacks AppKit happens to deliver first:
            // grip pushes, divider pops, and the pop takes the open hand off and leaves the resize
            // cursor sitting there over a grip. A pointer style is resolved by the view hierarchy
            // instead of by a stack, so the innermost one wins whatever order the events arrive in,
            // and a stray pop from the divider is repaired on the next mouse moved rather than
            // being permanent.
            .pointerStyle(.grabIdle)
            .onHover { inside in
                isHovered = inside
                onPointerOver(inside ? pane : nil)
            }
            .accessibilityElement()
            .accessibilityLabel("Move pane")
            .accessibilityHint("Drag onto another pane to move this one beside it")
    }
}
