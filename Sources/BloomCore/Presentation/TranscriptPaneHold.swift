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
/// **An arrival.** Pointing a pane at another conversation used to measure the whole window it
/// opened: the tail, and a beat later the four hundred rows behind it. None of that is measured up
/// front any more (see `TranscriptRowHeights.assumed`), so what is left is reading the rows and
/// measuring the one screen the reader actually lands on. Until that has happened the pane is a
/// transcript in pieces, so it is not drawn at all until it is in the place it belongs, and then
/// it is faded in.
///
/// **A split** is the third, and it is an arrival: `CenterPanesView` deliberately changes a pane's
/// `ForEach` identity when a tab goes from one pane to two, so the chat is rebuilt rather than
/// resized and has no pixels of its own to keep.
///
/// One rule for all three: hold, do the expensive thing, fade to it. `TranscriptHoldView` is the
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

    /// The deadline a hold of this kind is armed with, so that nothing has to arrive for it to
    /// end. See `TranscriptHoldView.hold(_:)`, which arms one for every hold it takes.
    public static func letsGo(of held: PaneHeld, underAHand: Bool) -> Duration {
        switch held {
        case .whatIsDrawn: underAHand ? quietUnderAHand : quiet
        case .nothing: arrival
        }
    }

    /// The longest a pane stays blank waiting for the conversation it has been pointed at.
    ///
    /// **What it is showing meanwhile is its own empty ground and never another conversation**, so
    /// this is a backstop rather than a length anybody watches: the pane is revealed the moment its
    /// rows are in and in the right place, which is a load from SQLite and a tail's worth of
    /// measuring away. This is what covers a load that never returns, a task cancelled on its way
    /// there, and a session with nothing in it at all.
    public static let arrival: Duration = .seconds(1)

    /// What a hold is holding, which is the whole of the difference between the triggers.
    ///
    /// Here rather than in the view, because the deadline and the rule above are decisions and a
    /// decision taken inside a view is a decision nothing can test.
    /// `TranscriptHoldView.Held` is this, spelled where the mechanism is.
    public enum PaneHeld: Equatable, Sendable {
        /// The pixels a pane already has, at the size it had them. A resize.
        case whatIsDrawn
        /// Nothing: the pane draws its own ground until it is ready. An arrival, and a split,
        /// which is an arrival in a pane that has just been built.
        case nothing
    }

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
