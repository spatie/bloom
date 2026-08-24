import Foundation

/// What hiding or unhiding a project looks like, which is two different things depending on one
/// switch, and what toggling that switch itself looks like.
///
/// **The gesture is one gesture and the animation is not.** With "Show hidden projects" off,
/// hiding REMOVES the project's row and every workspace row under it, so the change is an
/// appearance: the rows go, and what was below them closes up. With it on, hiding removes nothing:
/// the row stays exactly where it was and drops to the dimmed treatment, so the change is a
/// contrast and nothing moves at all. Using the wrong one of those in either case looks broken,
/// which is why this answers with a case rather than with a duration.
///
/// It is here rather than in the sidebar because a duration chosen inside a view is a duration
/// nothing can test, and because the three cases have to agree with each other about how long they
/// take: the toggle inserts several projects at once and the per-project gesture moves one, and
/// two different lengths for the same pane read as two apps.
public enum ProjectVisibilityMotion: Equatable, Sendable {
    /// Nothing to watch. Reduce Motion, and the first fill of a pane that has not settled yet.
    case instant
    /// The row stays put and changes contrast. Nothing is inserted, nothing is removed and nothing
    /// below it moves.
    case dim(seconds: Double)
    /// Rows arrive or leave, and everything below each of them travels to its new place.
    case reflow(seconds: Double)

    /// How long it takes, or nil when there is nothing to time.
    public var seconds: Double? {
        switch self {
        case .instant: nil
        case .dim(let seconds), .reflow(let seconds): seconds
        }
    }

    /// The one length this pane confirms anything in.
    ///
    /// `TranscriptMotion.arrival` settles a row in 220 milliseconds and it is the app's own
    /// register for "something you just did has landed". Reusing the number rather than choosing
    /// one is the whole point: hiding a project, unhiding it and turning the filter on are three
    /// versions of the same confirmation and would be three different apps at three lengths.
    public static let seconds = 0.22

    /// What one project being hidden or unhidden looks like.
    ///
    /// - Parameters:
    ///   - showingHidden: whether "Show hidden projects" is on, which is what decides whether the
    ///     row leaves the pane at all.
    ///   - reduceMotion: dropped rather than slowed, matching every other call site in the app.
    public static func hideGesture(
        showingHidden: Bool, reduceMotion: Bool
    ) -> ProjectVisibilityMotion {
        guard !reduceMotion else { return .instant }
        return showingHidden ? .dim(seconds: seconds) : .reflow(seconds: seconds)
    }

    /// What the "Show hidden projects" switch itself looks like.
    ///
    /// Always a reflow, and never a dim: the switch is the one gesture that can insert four
    /// project headers at four different depths, each bringing its workspace rows with it. The
    /// rows already on screen have to travel to their new places rather than be re-laid-out, which
    /// is what the caller's stable row identity buys and what this length is spent on.
    public static func filterToggle(reduceMotion: Bool) -> ProjectVisibilityMotion {
        reduceMotion ? .instant : .reflow(seconds: seconds)
    }

    /// A subagent's row leaving the pane because its work is done.
    ///
    /// Always a reflow, never a dim: the row is removed and everything below it closes up, which
    /// is the same change hiding a project makes with the filter off. It is the same LENGTH for
    /// the same reason the three above share one: a pane that closed a gap in 220 milliseconds
    /// for one reason and in some other number for another would be two apps. See
    /// `SubagentRetention` for when a row is removed at all.
    public static func subagentRemoval(reduceMotion: Bool) -> ProjectVisibilityMotion {
        reduceMotion ? .instant : .reflow(seconds: seconds)
    }

    /// Whether an arriving row should be faded in on top of the reflow.
    ///
    /// A row that is LEAVING has a place to leave from, and a row that is MOVING has a place to
    /// move from, so both of those are carried by the reflow alone. A row that is arriving has
    /// neither: without this it slides in from wherever the list decides, which reads as movement
    /// nobody asked for. `RowArrival` is the app's answer to exactly that and this is only the
    /// decision to use it.
    ///
    /// False for the per-project gesture with the filter on, because nothing arrives.
    public var fadesArrivals: Bool {
        if case .reflow = self { return true }
        return false
    }
}
