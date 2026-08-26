import Foundation

/// What opening or closing a folder in the inspector's two trees looks like.
///
/// The gesture is one gesture and it has two halves that are decided separately. **The chevron
/// turns whatever the folder holds**, because it is one small rotation on one glyph and costs the
/// same on a folder of two files and a folder of two thousand. **The rows below it only travel
/// while there are rows left on screen to travel**, which is what `rowLimit` is about.
///
/// Here rather than in the views because both trees have to answer it identically, and because a
/// threshold taken inside a view is a threshold nothing can test.
public enum TreeDisclosureMotion: Equatable, Sendable {
    /// There instantly, with nothing to watch. Reduce Motion, and an expansion too big to read.
    case instant
    /// Rows arrive or leave, and everything below them travels to its new place.
    case animated(seconds: Double)

    /// How long it takes, or nil when there is nothing to time.
    public var seconds: Double? {
        switch self {
        case .instant: nil
        case .animated(let seconds): seconds
        }
    }

    /// The most rows that can arrive or leave in one gesture and still be worth animating.
    ///
    /// At `Metrics.rowHeight`, forty rows is 1,120 points: more than the inspector column is tall
    /// on any display this window opens on. Above it every row that was under the folder has left
    /// the pane before the curve is a third through, so nothing is left travelling and all that
    /// remains is a block of new rows fading in place. That fade is exactly the effect this whole
    /// change exists to replace, so above the threshold it is more honest to show none of it.
    ///
    /// It is a legibility limit and not a cost limit. Both trees draw into a `LazyVStack`, which
    /// materialises about a screenful of rows however many the folder holds, so a large expansion
    /// is not the runaway that a per-frame animation over a whole window was: see `BusyPulse` for
    /// the 320,971 view graph updates that one measured at.
    public static let rowLimit = 40

    /// The rows making room, or not.
    ///
    /// - Parameter count: how many rows arrive or leave, whichever way the folder went. Zero for
    ///   an empty directory, which has nothing to animate even though its chevron still turns.
    public static func rows(changing count: Int, reduceMotion: Bool) -> TreeDisclosureMotion {
        guard count > 0, count <= rowLimit else { return .instant }
        return chevron(reduceMotion: reduceMotion)
    }

    /// The disclosure chevron turning.
    ///
    /// The length is `TranscriptMotion.disclosure`'s rather than one chosen here: a tool result
    /// unfolding in the transcript and a folder opening in the inspector are the same gesture in
    /// two panes, and two lengths would read as two apps. Reduce Motion drops it rather than
    /// slowing it, matching every other call site.
    public static func chevron(reduceMotion: Bool) -> TreeDisclosureMotion {
        guard let seconds = TranscriptMotion.disclosure(reduceMotion: reduceMotion) else {
            return .instant
        }
        return .animated(seconds: seconds)
    }
}
