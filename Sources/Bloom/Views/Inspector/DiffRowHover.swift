import SwiftUI
import AppKit

/// Which row of a run the pointer is over, told by AppKit rather than by SwiftUI.
///
/// **This is part of the fix for "we don't see the + anymore on hover to add the comment".** A run
/// draws its code as one selectable `Text` laid over the per line chrome, and `DiffRunView` used
/// to ask `.onContinuousHover` on the container which row the pointer was on. It reports the row
/// from a point rather than from a hit, which is what a run needs, and the rows the per line path
/// draws were never affected, which is why this looked like it had gone everywhere at once.
///
/// The paragraph that used to be here said a selectable `Text` swallowed the moved events over
/// its own glyphs and that this was why the `+` never appeared. **That was wrong, and it is
/// written down because it cost a day.** A standalone reproduction of this exact layout, one
/// selectable multi line `Text` over per line chrome in a lazy scroll view, reported every row
/// continuously through `.onContinuousHover` on the container. What was actually broken was two
/// other things, both fixed and both written up where they live: the tracking rect below, and the
/// row rebuild in `DiffRunView.Row`. A tracking area is still the better instrument here, because
/// it cannot be intercepted by whatever the code layer does next, but it was not the diagnosis.
///
/// **A tracking area cannot be intercepted, and this view takes no clicks.** `mouseEntered`,
/// `mouseMoved` and `mouseExited` are dispatched by the window to the tracking area's OWNER from
/// the area's geometry, with no reference to what `hitTest` says is on top. So this sits over the
/// text, hears every move, and returns nil from `hitTest` so that a click, a drag over the code
/// and the row's own context menu all pass straight through to what is underneath. It is the same
/// mechanism `ComposerTextView` and `TranscriptTextView` already use to find the chip under the
/// pointer inside a text view.
///
/// It reveals the `+` and decides nothing else, which is the rule `DiffRunView` set and this
/// keeps: the button takes the line it comments on from its own row, never from this, so a row
/// reported wrong would show a `+` in the wrong place and still comment in the right one.
struct DiffRowHover: NSViewRepresentable {
    /// How tall one row is. The arithmetic below is only honest because every line box in a run
    /// is exactly this, which is the same invariant the gutter beside it depends on.
    var rowHeight: CGFloat
    /// How many rows the run holds, so a point past the last one reports nothing.
    var rowCount: Int
    /// Called when the row under the pointer changes, and with nil when it leaves.
    var onChange: (Int?) -> Void

    func makeNSView(context: Context) -> RowHoverView {
        let view = RowHoverView()
        view.rowHeight = rowHeight
        view.rowCount = rowCount
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: RowHoverView, context: Context) {
        view.rowHeight = rowHeight
        view.rowCount = rowCount
        // Reassigned every pass because the closure is a fresh allocation each time, which is the
        // same reason `DiffRunView.==` cannot compare it.
        view.onChange = onChange
    }

    final class RowHoverView: NSView {
        var rowHeight: CGFloat = 1
        var rowCount = 0
        var onChange: ((Int?) -> Void)?

        /// The last row reported, so a move within one row says nothing. A run is 400 rows at
        /// most and a pointer crosses a row in a few frames, so this is the difference between
        /// one state write per row and one per mouse move.
        private var reported: Int??

        /// Top down, like the rows above it and like SwiftUI. Without this the arithmetic below
        /// would count from the bottom of the run and every `+` would appear on the mirror image
        /// of the row the pointer was on.
        override var isFlipped: Bool { true }

        /// Invisible to every gesture. See the head of this file: the tracking area still reports.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// **The rect is this view's own bounds, and `.inVisibleRect` is the thing that must not
        /// come back.** That option tells AppKit to keep the area in step with `visibleRect`, and
        /// a view SwiftUI hosts does not have one: measured here, a run 449.5 by 126 points
        /// reported a visible rect of `CGRect.infinite`. Every run in the diff therefore had a
        /// tracking area the size of everything, all of them overlapping, and a pointer that
        /// enters an area it never leaves is told once and never again. That is the whole of "the
        /// `+` appears on one line and stays there": one `mouseEntered` on arrival at the diff,
        /// no exits, no crossings, for the rest of the file.
        ///
        /// Rebuilt from `setFrameSize` below, because giving up `.inVisibleRect` gives up the
        /// self-updating that went with it.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self {
                removeTrackingArea(area)
            }
            // `.mouseMoved` is what carries the row to row crossings inside one run. The
            // enter and exit pair alone only says which run.
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self
            ))
        }

        /// The sheet is as wide as the file's longest line and the pane it sits in is resizable,
        /// so the run's frame moves under a hand that has not. With the rect fixed to `bounds`
        /// rather than tracking the visible rect, this is what keeps the two the same rectangle.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            report(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            report(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            report(nil)
        }

        /// The pointer has gone somewhere this view cannot see it, which a scroll does under a
        /// hand that has not moved.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { report(nil) }
        }

        private func report(at point: NSPoint) {
            guard rowHeight > 0, bounds.contains(point) else { return report(nil) }
            let index = Int(point.y / rowHeight)
            report((0..<rowCount).contains(index) ? index : nil)
        }

        private func report(_ row: Int?) {
            guard reported != row else { return }
            reported = row
            onChange?(row)
        }
    }
}
