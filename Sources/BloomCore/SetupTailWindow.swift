import Foundation

/// How much of a running setup log the transcript shows, as a share of the pane it is drawn in.
///
/// This was a constant, five lines, and a constant cannot answer the question that was asked of it.
/// Five lines is about a quarter of the transcript at the smallest window Bloom opens and nearer a
/// tenth of it on a large display, so "make setup bigger, it can take at least half of the chat
/// screen" has no number: the number that gives half a large window gives most of a laptop one. So
/// the window is worked out from the height it is being drawn into, and the answer is a proportion
/// at every size.
///
/// `Double` rather than `CGFloat`, and here rather than in the view, for the reason `ScrollEnd`
/// gives: a height is a number, nothing in this target has heard of CoreGraphics, and a decision
/// taken inside a view is a decision nothing can test.
public enum SetupTailWindow {
    /// The share of the transcript the running tail may take, which is what was asked for.
    ///
    /// Of the tail alone, not of the row: the header above it and the links below it are a further
    /// seventy points or so, so the block as a whole comes out a little over half. That is the
    /// right way round for a request phrased as "at least half".
    public static let share = 0.5

    /// The height the block holds from its first frame, and never goes below.
    ///
    /// Five, which is what `a98e055` settled on and why. A run that has printed fewer lines than
    /// its window holds used to grow a line at a time through the first seconds of every setup,
    /// and that is one of the two movers that commit killed. Holding the first five lines at the
    /// height five lines will take keeps those seconds exactly as still as they are today,
    /// whatever the pane's own size makes of the rest. See `lines(cap:logLines:)`.
    public static let settled = 5

    /// A pane squeezed to almost nothing still shows something moving.
    ///
    /// Three is what the block was before `a98e055`, and that commit's objection to three was that
    /// it is three seconds of history at the ordinary window, not that three lines is too few to
    /// read. A transcript under about 175 points, which is the terminal split dragged nearly to
    /// the top, is a pane where five lines of log and no conversation is the worse answer.
    public static let minimumCap = 3

    /// And a tall display does not hand over forty lines.
    ///
    /// Half of a transcript on a full screen 27 inch display is upwards of forty lines, and forty
    /// lines of a build log is not a tail any more: it is the whole log, drawn in the row that
    /// exists to summarise it, with the disclosure below it offering the same thing again. Thirty
    /// is half of a pane about a thousand points tall, which is a large window on this machine, so
    /// the ceiling binds only above that.
    public static let maximumCap = 30

    /// A failure is read rather than glanced at, and twelve lines is what that took.
    public static let failureFloor = 12

    /// The most lines the running tail may show in a pane this tall.
    ///
    /// `lineHeight` is asked of AppKit by the view, because it has to be the height SwiftUI
    /// actually lays a line of that face out on and the conversation can be set at any text size.
    /// Both are handed in so this stays a decision about proportions and nothing else.
    ///
    /// A pane that has not been laid out yet answers `settled` rather than `minimumCap`. A window
    /// opens, and a tab that is not the one on screen sits, with a container size of zero, and a
    /// block that collapsed to three lines on that frame and jumped to twenty five on the next
    /// would do it on every open. Five is the answer this row gave for a year; it is the right
    /// thing to say when the pane cannot yet be measured.
    public static func cap(paneHeight: Double, lineHeight: Double) -> Int {
        guard paneHeight > 0, lineHeight > 0 else { return settled }
        let fits = Int((paneHeight * share / lineHeight).rounded(.down))
        return min(maximumCap, max(minimumCap, fits))
    }

    /// How many lines tall to draw the block, given that cap and how much log there is to put in it.
    ///
    /// **The block is not simply drawn at the cap, and that is the whole of what makes a tall tail
    /// safe.** At the smallest window the difference between a cap and a fill is two or three empty
    /// lines and nobody would notice. At half of a large window it is four hundred points of ruled,
    /// empty box sitting over the conversation for as long as a quiet script takes to finish, and a
    /// setup script that prints two lines and then spends a minute in `composer install` is not
    /// unusual.
    ///
    /// So the block is the size of what is in it, between `settled` and the cap. It cannot shrink
    /// below the five lines it starts at, which is the case `a98e055` measured and fixed, and it
    /// grows above that only when a real line of output has arrived to fill the space. It stops for
    /// good once the log passes the cap, which for a chatty script is the first few seconds. What
    /// it never does is depend on how long the lines are: that is the wrap driven oscillation the
    /// same commit killed, it moved the sentence below by thirty one points in both directions
    /// forever, and it stays killed by the view holding each running line to one line.
    public static func lines(cap: Int, logLines: Int) -> Int {
        min(cap, max(min(settled, cap), logLines))
    }

    /// How many lines a failed run shows without being asked.
    ///
    /// Twelve, or the cap where the pane is big enough to want more, and never fewer than a running
    /// run in the same pane. A failure that showed less of its log than a success would be the
    /// wrong way round in the one case where the log IS the message.
    public static func failureLines(cap: Int) -> Int {
        max(failureFloor, cap)
    }
}
