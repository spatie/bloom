import Foundation

/// Whether a scrolling view is at the end of its content, and therefore whether there is anything
/// below to offer to go to.
///
/// One question with one answer, in the core, because three separate pieces of the window are
/// answers to it: the "jump to newest" pill, whether an arriving line of a setup log may move the
/// view, and whether the transcript keeps itself pinned to the live end while a turn streams. It
/// was worked out inside a view from a scroll geometry, which is a decision nothing could test.
///
/// **Two of the three rules are about a view that cannot scroll at all, and they are the point.**
/// A reader can only be away from the end of something that has an end below them. Content that
/// fits in the pane has none, and neither does a pane that has not been laid out yet or has been
/// squeezed to nothing, which happens more often than it sounds: a tab that is not the one on
/// screen, the frame a window opens on, a split divider dragged to the floor. Left to the
/// subtraction alone, every one of those reads as "a long way from the end", because the content
/// is its full height and the viewport is zero. That is how an offer to jump to the newest row
/// ends up floating over a conversation whose last line is already on screen with empty space
/// under it.
///
/// `Double` rather than `CGFloat`, because nothing else in this target has heard of CoreGraphics
/// and a scroll offset is a number.
public enum ScrollEnd {
    /// How far from the end still counts as following along.
    ///
    /// A reader who has nudged the wheel by a line has not left the conversation, and putting a
    /// pill over the composer for that would be an offer to go where they already are.
    public static let threshold: Double = 96

    public static func isAtEnd(
        contentHeight: Double,
        viewportHeight: Double,
        offset: Double,
        threshold: Double = threshold
    ) -> Bool {
        // Nothing has been measured, or there is nothing to measure into. Not an answer of "no",
        // which the subtraction below would give, and which is the wrong way round: an unlaid pane
        // must not claim its reader has scrolled away from anything.
        guard viewportHeight > 0 else { return true }
        // Nothing to scroll. There is no end below the reader, so they are at it, wherever the
        // offset says they are.
        guard contentHeight > viewportHeight else { return true }
        return contentHeight - offset - viewportHeight < threshold
    }
}
