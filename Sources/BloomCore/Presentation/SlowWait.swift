import Foundation

/// When a wait has gone on long enough to be worth saying anything about.
///
/// # Why there is a delay at all
///
/// Almost every wait in this window is over before it is a wait. Coming back to a workspace this
/// launch has already opened, the conversation is read from SQLite and folded into rows in a few
/// tens of milliseconds, and a spinner put up for that is a spinner that appears and disappears
/// inside three frames. What a person sees then is not "it was loading", it is a flicker, and a
/// flicker is read as a fault. The pane is better off holding still.
///
/// The waits that are worth marking are the other kind: a conversation of several thousand rows,
/// on a machine with four agents running in it, where the pane really does sit with nothing in it
/// for long enough to wonder whether the click landed. Half a second is the line between the two,
/// and it is not a number picked for this app: it is the same threshold every platform's guidance
/// has drawn for decades between "instantaneous" and "the user has noticed", and it is the point
/// at which somebody starts looking for a reason rather than waiting.
///
/// # Why it is here rather than a `500` in a view
///
/// Because a view cannot be tested, and the three answers this has to get right are exactly the
/// kind that go wrong quietly: nothing before the threshold, something after it, and nothing at
/// all for a wait that has already ended. The last of those is the flicker, arriving by another
/// route: a timer that fires after the content has landed and puts a spinner over it.
///
/// `Duration` rather than `TimeInterval`, so the caller measures with a `ContinuousClock` and not
/// with a wall clock that can be moved under it mid wait.
public enum SlowWait {
    /// How long a wait is allowed to run before the pane admits to it.
    public static let threshold: Duration = .milliseconds(500)

    /// Whether the pane should be drawing anything about this wait.
    ///
    /// - Parameters:
    ///   - waited: how long the pane has had nothing to draw.
    ///   - isOver: whether the wait ended before this was asked, in which case the answer is no
    ///     however long it ran. A caller that measured the elapsed time and only then noticed the
    ///     content had arrived passes true here, and gets silence rather than one frame of
    ///     spinner over a conversation that is already on screen.
    ///   - threshold: the line between the two, defaulted so a caller does not repeat it.
    public static func isShowing(
        waited: Duration, isOver: Bool = false, threshold: Duration = threshold
    ) -> Bool {
        !isOver && waited >= threshold
    }

    /// How much longer to stay quiet for, or nil when staying quiet cannot change the answer.
    ///
    /// Handed straight to `sleep(for:)`, so a pane sleeps exactly once for exactly the remainder
    /// rather than waking on a tick to ask a question whose answer it could have worked out.
    public static func quiet(
        after waited: Duration = .zero, threshold: Duration = threshold
    ) -> Duration? {
        waited < threshold ? threshold - waited : nil
    }
}
