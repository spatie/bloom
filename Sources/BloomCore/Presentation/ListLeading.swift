import Foundation

/// The gap between two items of a markdown list, in the rhythm the reader chose.
///
/// **The bug this exists to fix.** The conversation's line height moved every line of prose in the
/// transcript and did not move the gaps between list items, so raising it opened a paragraph up
/// and left a bulleted answer set exactly as it was. Those gaps came from `Metrics.spacingTight`
/// and `Metrics.spacing`, two points and six, which are the window's spacing scale: fixed numbers
/// that know nothing about the size the text is set at or the leading the reader asked for. At the
/// default step that made a tight list's items sit two points apart while the wrapped lines inside
/// one item sat three apart, which is the wrong way round and is what made the lists look broken
/// in the report: an item's own lines belonged to each other less than the items did.
///
/// **So an item is separated by the same air its own wrapped lines are given.** `ratio` here is
/// `ChatLineHeight.listRatio`, the tighter rhythm a list's wrapped lines are already set with, and
/// `TextLeading.overPointSize` turns it into the points those lines are led by. Handing that same
/// number to the stack between the items makes the distance from the last line of one item to the
/// first line of the next exactly the distance between two lines within an item, which is what a
/// tight list is: no blank line in the source, no blank line in the render.
///
/// **A loose list gets twice it**, which is one further line's worth of leading and lands back on
/// where these gaps were already calibrated: six points at the default step, the number the view
/// was hard coding, so a reader who never touches the setting sees the list they had.
///
/// There is no floor under either. One was tried at the two points a tight list used to be given,
/// and it made the two tightest steps answer the same number, which is a control with a segment
/// that does nothing. The tightest step sits under the WCAG 1.4.12 figure and is offered only
/// because a reader asks for it by name; at that step the lines inside an item are a point apart
/// as well, and a list as dense as the prose around it is exactly what was asked for.
public enum ListLeading {
    /// - Parameters:
    ///   - tight: markdown's own flag for a list whose items are not separated by blank lines. A
    ///     task list carries no such flag and is always tight, the way it is written.
    ///   - lineHeight: the line box the item's text is laid out in, which only AppKit can measure.
    ///   - pointSize: the size that text is set at.
    ///   - ratio: `ChatLineHeight.listRatio`, so this and the item's own `lineSpacing` are the one
    ///     number. Passing the prose ratio here would separate items by more air than their own
    ///     lines get, which is the bug above with its sign flipped.
    public static func betweenItems(
        tight: Bool, lineHeight: Double, pointSize: Double, ratio: Double
    ) -> Double {
        let leading = TextLeading.overPointSize(
            lineHeight: lineHeight, pointSize: pointSize, ratio: ratio
        )
        return tight ? leading : leading * 2
    }
}
