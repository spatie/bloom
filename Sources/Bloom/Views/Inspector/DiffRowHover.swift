import SwiftUI
import AppKit

/// Which row of a run the pointer is over, told by AppKit rather than by SwiftUI.
///
/// **This is the fix for "we don't see the + anymore on hover to add the comment".** A run draws
/// its code as one selectable `Text` laid over the per line chrome, and `DiffRunView` asked
/// `.onContinuousHover` on the container which row the pointer was on. That modifier needs a
/// stream of moved events, and a selectable `Text` is backed by text machinery that takes the
/// moves over its own glyphs: the pointer entered the run, got one phase at the boundary, and
/// then nothing more while it was over the code, which is where a reader's pointer spends all of
/// its time. So the `+` stayed hidden on every row of every run, and since `DiffRunGrouping` puts
/// any two consecutive lines in a run, that is nearly every row in a diff. `DiffRunView`'s own
/// note had already flagged this as the thing to doubt, and it turned out to be right.
///
/// `.onHover` was never affected and still is not, which is why the per line rows kept working
/// and made this look like it had gone everywhere at once. It answers "inside or outside" from
/// the pointer's position against a frame; it does not need the moves.
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

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self {
                removeTrackingArea(area)
            }
            // `.inVisibleRect` keeps the area right through a resize and a scroll without this
            // view being asked to rebuild it, and `.mouseMoved` is what makes the moves arrive at
            // all rather than only the crossings.
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
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
