import Foundation

/// Where a transcript's viewport has to go: to keep a reader on the row they were on, and to be
/// at the end of the conversation rather than nearly at it.
///
/// **The arithmetic is four lines and every one of them was a bug in a view once.**
///
/// A `LazyVStack` can only be put back to a point, and a point measured against a document that
/// has since grown four hundred rows at the top names somewhere else entirely: the reader is
/// thrown backwards through the conversation by exactly what was added. A table knows where every
/// row is, so the place can be a ROW and an offset from the top of the pane, which nothing added
/// above can change. `delta` writes that down and `offset` puts it back.
///
/// The end is the other half. A row being *visible* is not the end: the last row of a transcript
/// is often taller than the pane, so a scroll that stops when its top comes into view leaves most
/// of it, and the whole of anything after it, below the fold. The end of a scroll view is one
/// number, `contentHeight - viewportHeight`, and nothing else means it.
public enum TranscriptAnchor {
    /// How far below the top of the pane the anchored row starts, written down before something
    /// moves under the reader.
    ///
    /// Usually negative: the row at the top of the pane is normally part way scrolled off it.
    public static func delta(rowTop: Double, viewportTop: Double) -> Double {
        rowTop - viewportTop
    }

    /// Where the viewport goes to put that row back exactly where it was.
    public static func offset(rowTop: Double, delta: Double) -> Double {
        rowTop - delta
    }

    /// The furthest down a viewport can be scrolled: the end of the content.
    ///
    /// Never negative, because content shorter than the pane has no end below the reader to go to.
    /// See `ScrollEnd`, which makes the same two guards for the same reason.
    public static func end(contentHeight: Double, viewportHeight: Double) -> Double {
        max(0, contentHeight - viewportHeight)
    }

    /// A wanted offset brought inside the range the viewport can actually be at.
    ///
    /// Every scroll in the transcript goes through this, including the ones aimed at the end: a
    /// caller that asks for the end by naming a number past it gets the end, and one that asks for
    /// somewhere above the top gets the top.
    public static func clamped(
        _ offset: Double, contentHeight: Double, viewportHeight: Double
    ) -> Double {
        min(max(0, offset), end(contentHeight: contentHeight, viewportHeight: viewportHeight))
    }

    /// Where the viewport goes to put a row at a given place in the pane.
    ///
    /// `anchor` is the fraction of the pane the row's own span is lined up with, which is the
    /// same convention SwiftUI's `UnitPoint` uses and the same three values the transcript asks
    /// for: nought puts the row's top at the top of the pane, a half centres it, one puts its
    /// bottom at the bottom.
    ///
    /// Not clamped here. The caller clamps, because only it knows the content height, and a row
    /// near either end of a conversation resolves to a number outside the range on purpose.
    public static func offset(
        rowTop: Double, rowHeight: Double, viewportHeight: Double, anchor: Double
    ) -> Double {
        rowTop + rowHeight * anchor - viewportHeight * anchor
    }

    /// Whether a viewport that was put at the end is still there.
    ///
    /// **Exact, and deliberately not `ScrollEnd.isAtEnd`.** That one answers "is the reader still
    /// following along", with a threshold of a line or two, because a reader who nudged the wheel
    /// has not left the conversation. This answers "did the instruction to be at the end survive",
    /// and a transcript that is ninety points short of its newest row is a transcript that did not
    /// do what the pill was pressed for. One point of slack, for the fractions a clip view's own
    /// arithmetic lands on.
    public static func isAtEnd(
        offset: Double, contentHeight: Double, viewportHeight: Double
    ) -> Bool {
        end(contentHeight: contentHeight, viewportHeight: viewportHeight) - offset <= 1
    }
}
