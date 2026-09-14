import Foundation

/// When a pane holds its transcript back, and what it measures when it reflows.
///
/// **The measurement behind both halves.** A transcript row's height is only known once SwiftUI
/// has laid it out at a width, which is about a tenth of a millisecond a row on a kept hosting
/// controller (see `TranscriptTable.Coordinator.measure`), and there are two moments that ask for
/// a great many of them at once.
///
/// **An arrival.** Pointing a pane at another conversation used to measure the whole window it
/// opened: the tail, and a beat later the four hundred rows behind it. None of that is measured up
/// front any more (see `TranscriptRowHeights.assumed`), so what is left is reading the rows and
/// measuring the one screen the reader actually lands on. Until that has happened the pane is a
/// transcript in pieces, so it is not drawn at all until it is in the place it belongs, and then
/// it is faded in.
///
/// **A split** is an arrival too: `CenterPanesView` deliberately changes a pane's `ForEach`
/// identity when a tab goes from one pane to two, so the chat is rebuilt rather than resized.
///
/// **A resize is not held.** It used to be: the pane kept the pixels it had while a divider or a
/// window edge moved, and crossfaded to the reflowed transcript when the hand came off. That was
/// priced at two milliseconds a row, when every measurement built a fresh `NSHostingView`. At a
/// tenth of that, measuring the rows on screen fits in a frame, and the fade at the end of every
/// drag was a distraction nobody needed. So a width change reflows as it happens, measuring what
/// is visible, and `eager` below is measured once the width has stopped moving.
public enum TranscriptPaneHold {
    /// The longest a pane stays blank waiting for the conversation it has been pointed at.
    ///
    /// **What it is showing meanwhile is its own empty ground and never another conversation**, so
    /// this is a backstop rather than a length anybody watches: the pane is revealed the moment its
    /// rows are in and in the right place, which is a load from SQLite and a tail's worth of
    /// measuring away. This is what covers a load that never returns, a task cancelled on its way
    /// there, and a session with nothing in it at all.
    public static let arrival: Duration = .seconds(1)

    /// The most rows measured either side of the ones on screen.
    ///
    /// A margin so that a small scroll after a resize does not land on an estimate, and a cap so
    /// that a pane full of empty rows cannot decide to measure a whole conversation.
    public static let margin = 120

    /// The rows measured exactly once a reflow has settled, given the rows the pane can see.
    ///
    /// Everything visible is in it, always: a row drawn at a height measured for another width is
    /// a gap or an overlap the reader is looking at. Every other row keeps its old height as an
    /// estimate until it is drawn.
    public static func eager(visible: Range<Int>, count: Int) -> Range<Int> {
        guard count > 0, !visible.isEmpty else { return 0..<0 }
        let reach = min(visible.count, margin)
        let lower = max(0, visible.lowerBound - reach)
        let upper = min(count, visible.upperBound + reach)
        guard lower < upper else { return 0..<0 }
        return lower..<upper
    }
}
