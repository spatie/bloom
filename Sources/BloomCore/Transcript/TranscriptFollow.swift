import Foundation

/// How the transcript keeps up with content arriving at the live end.
///
/// **This is about the reader who is already at the end.** Somebody who has scrolled up to read
/// something is nobody's business but their own: `ScrollEnd` says who is at the end, the jump pill
/// says there is more below, and nothing here ever moves a view that somebody else has taken. That
/// one rule is what makes the rest of this safe.
///
/// ## Whose gap it is, which is not the same question as how wide it is
///
/// That rule used to be a distance: a gap wider than `ScrollEnd.threshold` was abandoned, whatever
/// had opened it. One number was answering two questions. "Has the reader scrolled away" is
/// answered by a flag, because the reader either took the view or did not, and `ownsGap` is that
/// flag: the caller put the view where it is and nothing has moved it since. "Has our own travel
/// fallen behind" is a distance, and the answer to it is to catch up rather than to give up.
///
/// Reported as the transcript stopping following part way through a turn and never starting
/// again. A stored row replacing the tail with a taller block, a tool result landing whole, a
/// height correction below the fold or one starved display link frame each open a gap in a single
/// step while the view is mid travel, and past ninety six points the following simply stopped:
/// the link stayed up because a turn was still running, so `endLink` was never reached, and when
/// the turn ended `endLink`'s own at-the-end guard meant nothing was handed back either.
///
/// ## Why a settle rather than a step per row
///
/// A line landing under a reader who is at the end used to put the view at the end in a single
/// frame, and what that reads as is the whole conversation jolting upwards by a row. The eye is
/// mid sentence and the sentence moves. A short travel over the same distance says the same thing
/// and lets the eye ride it.
///
/// ## Why an exponential approach rather than a curve with a length
///
/// Because the target moves. A delta is a handful of characters arriving many times a second, and
/// an animation with a start, an end and a duration has to be restarted every time the end of the
/// content moves, which is an animation that never arrives. An exponential approach has no
/// duration to restart: it is a rule about this frame only, so a growth that lands mid travel
/// simply moves the target and the same travel carries on towards the new one. That is the whole
/// of the coalescing, and there is no window to tune.
///
/// The lag it settles at is worth stating, because it is what stops this needing a rate limit of
/// its own. Content growing steadily at `r` points a second leaves the view `r * timeConstant`
/// points behind, so at a fifth of a second per line of prose the view trails by a couple of
/// points, and it would take growth of well over a thousand points a second to trail by the
/// `ScrollEnd.threshold` that would put the jump pill up. Nothing an agent prints does that.
public enum TranscriptFollow {
    /// How far back the view is put when content lands under a reader who is at the end, in
    /// points, and therefore how much travel there is to watch.
    ///
    /// **Three quarters of `ScrollEnd.threshold`, and it is a ceiling rather than a distance.** A
    /// row is put back by its own height so that what the eye was reading stays where it was, but
    /// a tool result unfolding or a forty line answer landing whole would otherwise put the reader
    /// most of a pane behind and then drag them through it, which is a tour rather than a settle.
    /// Capped here, the far end of a tall row's arrival is what gets travelled and the rest of it
    /// is simply where it lands.
    ///
    /// Under the threshold rather than at it, because the pill is drawn from a measurement that
    /// can be a frame stale: at exactly the threshold a full take-back would read as "not at the
    /// end" for as long as it took to travel, and the offer to jump to the newest row would blink
    /// on every line that arrived.
    public static let takeBack: Double = ScrollEnd.threshold * 0.75

    /// How quickly the view closes the gap, as the time constant of the approach.
    ///
    /// **Was a twentieth of a second, and that was too quick to read.** The arithmetic was right
    /// and the premise was wrong: a full `takeBack` of 72 points did settle in about a quarter of
    /// a second, but a single tool row arriving only grows the content by about 28 points, and 28
    /// points closed on a twentieth of a second time constant is over in roughly 150 milliseconds.
    /// What that looks like is the jump it was written to replace. The owner's report, watching
    /// real turns, was that the transcript still went "suddenly to the bottom without any
    /// animation".
    ///
    /// Nearly a tenth of a second instead, which puts an ordinary row's travel at about a quarter
    /// of a second and a full take-back at about the same as the jump pill's glide. Longer than
    /// this and the view is visibly behind the words, which is the failure in the other direction.
    public static let timeConstant: Double = 0.09

    /// Within this many points the travel is over. Half a point is under a pixel on every display
    /// this app runs on, so the last of the approach is spent rather than watched.
    public static let arrived: Double = 0.5

    /// The smallest step worth taking, in points.
    ///
    /// **A device pixel, because a step smaller than one is not a step.** The offset this hands
    /// back is written to a clip view whose origin is snapped to the backing store, and read back
    /// on the next frame it is the same number it was: an exponential approach spends its last
    /// point and a half in steps of a fifth of one, every one of which snaps back to where it
    /// started. Measured against a real hosted scroll view, the travel stopped a point and a half
    /// short and stayed there for as long as the link was up, which also means it never reported
    /// itself as arrived and never handed the live end back.
    ///
    /// Never more than what is left, so this cannot overshoot the end.
    public static let smallestStep: Double = 1

    /// The longest frame this will integrate over.
    ///
    /// A display link that has been starved, by a layout pass over a long transcript or by the
    /// machine being busy, hands back the whole of the gap since the last frame. Integrating that
    /// literally would jump most of the remaining distance in one step, which is the teleport this
    /// exists to replace, so a late frame is treated as an ordinary one.
    public static let longestFrame: Double = 1.0 / 30

    /// Whether this travel is owed at all.
    ///
    /// Reduce Motion drops it rather than slowing it, which is what `TranscriptMotion` does with
    /// every other movement in this app and for the same reason: the setting is about movement,
    /// and there is no slower version of following a turn worth having. With the travel dropped
    /// the transcript keeps the instant pin it has always had, which is not a degraded answer.
    public static func travels(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// What to do with the view this frame.
    public enum Move: Equatable, Sendable {
        /// Nothing. Either the view is at the end already, or the reader is somewhere else and it
        /// is not this type's business.
        case rest
        /// Put the view's offset here.
        case settle(Double)
    }

    /// Where the travel starts from, when content has just grown under a reader at the end.
    ///
    /// Called with what the view grew by since the last frame. A view that is away from the end
    /// and is not the caller's own is left exactly where it is, which is the same rule `step`
    /// follows and is why this cannot yank anybody: growth is only ever taken back from somebody
    /// who was watching the end of it.
    ///
    /// It returns the offset unchanged rather than an optional so that a caller cannot honour the
    /// take-back and skip the guard.
    ///
    /// **`ownsGap` is also what stops a gap of this object's own running away**, which is the
    /// stranding in the header. Content growing does not move the offset, so an arrival mid travel
    /// simply adds its own height to a gap that was already open, and enough of them in a row put
    /// the view further from the end than the following was ever willing to travel.
    ///
    /// So what is taken back is how far behind the view already is or how much has just arrived,
    /// whichever is the more, capped either way. The two are the same number in the case this was
    /// written for, because something else pins the view to the end on the pass that grows the
    /// content and the arrival is then the whole of the distance. They come apart mid travel, and
    /// there the larger one is the gap: below the cap the arithmetic hands back the offset it was
    /// given, which is the coalescing rule unchanged, and above it the excess is given up in one
    /// step so that what is left is a travel rather than a tour.
    public static func start(offset: Double, end: Double, grew: Double, ownsGap: Bool) -> Double {
        guard grew > 0, end > 0 else { return offset }
        let gap = end - offset
        // Somebody else's open gap is somebody reading further up, and taking a growth back from
        // them is the one thing this file may never do. Ours, or a view the content has just been
        // pinned under, is the only thing there is to take back from.
        guard ownsGap || gap <= arrived else { return offset }
        return max(0, end - min(max(gap, grew), takeBack))
    }

    /// This frame's offset, or `rest`.
    ///
    /// `frame` is the time since the last one, in seconds. `ownsGap` is whether the view is where
    /// this object left it: see the header, and `start`.
    public static func step(offset: Double, end: Double, frame: Double, ownsGap: Bool) -> Move {
        guard end > 0 else { return .rest }
        let gap = end - offset

        // Below the end, which is content that has shrunk under the view: a row folded up, a
        // streaming block replaced by a shorter stored one. There is nothing to watch travelling
        // backwards, so it is simply put right.
        guard gap > -arrived else { return .settle(end) }
        guard gap > arrived else { return .rest }
        if gap > ScrollEnd.threshold {
            // Somebody reading further up. Not ours, at any distance, ever.
            guard ownsGap else { return .rest }
            // And the same distance when the gap is this object's own is a travel that has fallen
            // behind, which is jumped rather than abandoned. To `takeBack` rather than to the end,
            // so that the last of it is still something the eye can follow: this is what the same
            // arrival would have looked like had every frame been on time.
            return .settle(end - takeBack)
        }

        let elapsed = min(max(frame, 0), longestFrame)
        guard elapsed > 0 else { return .rest }
        let travelled = max(gap * (1 - exp(-elapsed / timeConstant)), min(gap, smallestStep))
        let next = offset + travelled
        // The last half point is spent rather than watched, and this is also what stops the
        // approach from asymptoting forever and holding the display link open.
        return end - next <= arrived ? .settle(end) : .settle(next)
    }
}
