import Foundation

/// How far ahead of a reader a settled transcript prepares itself, and how much of that is worth
/// doing at once.
///
/// **A row costs once, at its first build, and never again.** That is the one thing every build of
/// a bad night agreed on, and the reader said it himself, unprompted, of four different builds:
/// "for the items that i've already scrolled over, it's butter smooth". Nothing that made rows
/// cheaper changed it, and nothing that changed the window changed it either. So the answer is not
/// to make the first build cheaper, it is to have already done it.
///
/// A pane that has stopped moving has main thread time nobody is watching. This is how much of it
/// to spend, and the two numbers pull against each other.
///
/// **Points rather than rows, because a row is not a unit of anything here.** A row that draws
/// nothing is a hundredth of a point tall and a paragraph of prose is several hundred, so four
/// hundred rows is a screenful in one part of a conversation and forty screens in another. What
/// the reader is about to travel through is measured in points, which is why the reach is.
///
/// **And a cap in rows anyway, because points do not bound the work.** A band of points over the
/// older history can hold hundreds of rows that draw nothing, and preparing each of them still
/// costs a hosting view. The cap is what stops a settle turning into a second of main thread; the
/// reach is what makes the cap land on rows the reader will actually meet.
public enum TranscriptWarming {
    /// The furthest a warm pass reaches above the viewport, in points.
    ///
    /// Two screens, which is the "viewport or two" a reader flicking back covers between one stop
    /// and the next. The ceiling is Zed's, whose `list` keeps a 2,048 point eagerly measured
    /// overdraw buffer for exactly this shape of view: a chat-shaped log somebody scrolls back
    /// through. It matters on a tall display, where two screens is a great deal of conversation
    /// and the reader is no more likely to travel all of it.
    public static let ceiling: Double = 2_048

    /// The most rows one pass prepares. See the header: the reach cannot bound the work on its own.
    ///
    /// Sixty is about a screenful of ordinary rows. At the two milliseconds a hosting view costs
    /// to build and lay out, a full pass is something over a tenth of a second of a main thread
    /// nobody is using, and it is given up between rows rather than at the end.
    public static let mostRows = 60

    /// How far above the viewport to prepare, given the height of the viewport.
    public static func reach(viewport: Double) -> Double {
        guard viewport > 0 else { return 0 }
        return min(viewport * 2, ceiling)
    }

    /// Which rows of a band are worth preparing: the ones nearest the reader.
    ///
    /// **Nearest, because those are the ones met first.** A band above a reader scrolling up is
    /// travelled from its bottom edge, so a pass that started at the top of it would prepare the
    /// rows they reach last and be interrupted before the ones they reach first.
    public static func worthWarming(_ band: Range<Int>, most: Int = mostRows) -> Range<Int> {
        guard most > 0 else { return band.upperBound..<band.upperBound }
        guard band.count > most else { return band }
        return (band.upperBound - most)..<band.upperBound
    }
}
