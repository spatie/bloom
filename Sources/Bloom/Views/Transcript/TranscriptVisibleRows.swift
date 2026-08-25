import Foundation

/// Which rows are on screen, so that leaving a conversation can write down WHICH row the reader
/// was at rather than how many points down they were.
///
/// # Why a point is not a place
///
/// The content height of a transcript is not a fact about the conversation, it is a fact about
/// what the lazy stack has bothered to measure. Driven through the owner's own report, one chat
/// left at its top and visited three times, the same session's content came out 35,246 points,
/// then 17,235, then 24,407: the rows near the viewport get measured and everything else is
/// guessed, and the guess depends on which rows happened to be realised. A point offset written
/// against one of those numbers and read against another names a different row, which is what
/// "the position does weird things" is.
///
/// A row is a row at every one of those heights.
///
/// # Why this rather than `scrollTargetLayout`
///
/// SwiftUI will hand over the row at the top of a scroll target layout, and that layout was
/// measured on this list and is too expensive to keep: scrolling a 225 row chat, p99 went from
/// 21.8ms to 39.2ms and the worst frame from 35.8ms to 70.7ms with nothing else changed, because
/// it computes target geometry for every subview on every pass.
///
/// A visibility callback is a different shape of cost. It fires when a row ENTERS or LEAVES the
/// viewport, which is twice per row per pass over it, rather than once per subview per frame. The
/// set it maintains is read once, when the pane is asked to remember where it was.
///
/// **Not observed, deliberately.** This is written on every row that crosses the edge of the
/// viewport, which during a flick is dozens a second, and nothing draws from it: it is read by
/// `remember`, outside a body. As `@Observable` it would invalidate the list on every row that
/// scrolled past, which is the opposite of the point. See `GeometryBox` for the same argument.
@MainActor
final class TranscriptVisibleRows {
    private var seqs: Set<Int> = []

    func note(_ seq: Int, isVisible: Bool) {
        if isVisible {
            seqs.insert(seq)
        } else {
            seqs.remove(seq)
        }
    }

    /// The topmost row on screen, which is where the reader is.
    ///
    /// The minimum rather than the first the set happened to see: a set has no order, and rows
    /// arrive in it in whatever order they crossed the edge.
    var topmost: Int? { seqs.min() }

    /// Forgotten when the pane is pointed at another conversation, because a row that is visible
    /// in one session is not a row in another.
    func forget() { seqs.removeAll() }
}
