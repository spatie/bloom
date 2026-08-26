import Foundation

/// When a pane holds its transcript back, and what it shows when it lets go.
///
/// **The measurement behind both halves.** A transcript row's height is only known once an
/// `NSHostingView` has laid it out, at about two milliseconds each, and there are two moments that
/// ask for a great many of them at once.
///
/// **A resize.** A width change invalidates every cached height, so an 1,855 row session costs
/// about four seconds of main thread, and a drag asked for that several times over: the old
/// debounce fired in every pause of the hand. So a drag remeasures nothing at all. The pane grows
/// and the transcript keeps the size it had, the way Safari keeps a page while its sidebar moves,
/// and the reflow happens once when the hand comes off.
///
/// **An arrival.** Pointing a pane at another conversation measures the tail of it, and a beat
/// later the four hundred rows behind that. Until both have landed the pane is a transcript in
/// pieces: rows at the top, then a jump to the live end. So it is not drawn at all until it is in
/// the place it belongs, and then it is faded in.
///
/// One rule for both: hold, do the expensive thing, fade to it. `TranscriptHoldView` is the
/// mechanism, and this is the part that can be tested.
public enum TranscriptPaneHold {
    /// Whether a width change is worth holding the transcript for.
    ///
    /// A width nothing has been drawn at yet is not one: the first layout of a pane must reflow
    /// rather than freeze, or an offscreen capture photographs an empty transcript.
    public static func holds(from: Double, to: Double) -> Bool {
        guard from > TranscriptRowHeights.narrowest, to > TranscriptRowHeights.narrowest else {
            return false
        }
        return !TranscriptRowHeights.isSameWidth(from, to)
    }

    /// How long after the last width change a hold lets go on its own.
    ///
    /// Every hold is armed with one of these, so there is no gesture whose end event going missing
    /// can leave a frozen picture on screen. A window zoom, a display change and `--window-size`
    /// are all held and released by this alone.
    public static let quiet: Duration = .milliseconds(200)

    /// The same deadline while a hand is known to be on a divider.
    ///
    /// Long, because a hand that pauses mid drag has not finished dragging and a reflow under it
    /// would be a fade nobody asked for. Still finite, so a gesture that never reports its end
    /// unfreezes anyway.
    public static let quietUnderAHand: Duration = .seconds(2)

    public static func letsGo(underAHand: Bool) -> Duration {
        underAHand ? quietUnderAHand : quiet
    }

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

    /// The rows measured exactly before the transcript comes back, given the rows the pane can see.
    ///
    /// Everything visible is in it, always: the fade is over what the reader is looking at, and a
    /// row drawn at a height measured for another width is the blank the fade would be covering.
    /// Every other row keeps its old height as an estimate until it is drawn.
    public static func eager(visible: Range<Int>, count: Int) -> Range<Int> {
        guard count > 0, !visible.isEmpty else { return 0..<0 }
        let reach = min(visible.count, margin)
        let lower = max(0, visible.lowerBound - reach)
        let upper = min(count, visible.upperBound + reach)
        guard lower < upper else { return 0..<0 }
        return lower..<upper
    }
}
