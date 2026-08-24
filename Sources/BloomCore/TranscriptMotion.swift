import Foundation

/// What the transcript is allowed to animate, and for how long.
///
/// Three different things get called "text appearing in the chat window" and they do not want the
/// same treatment, so the rules for telling them apart live here rather than inside a view where
/// nothing could test them.
///
/// **A row landing in the list fades.** A tool call, a result, a turn footer, a notice. It lands
/// where a "Running Bash" line was and it reads better as a settle than as a pop. `fadesOnArrival`
/// is that rule, and `RowArrival` in the app is the mechanism.
///
/// **A block of streamed prose fades once, when the block first has anything in it.** Not per
/// delta. A delta is a handful of characters arriving many times a second, and a fade started on
/// each one is a shimmer at the tail of the answer, which is a good deal worse than the pop it
/// would be replacing. So the fade belongs to the block rather than to the text, and there is
/// nothing here to decide per delta: see `StreamingRowView`.
///
/// **Keeping up with the end of a running turn is `TranscriptFollow`**, which is a fourth thing
/// and is not here: it is a rule about where the view sits rather than about how a row is drawn,
/// and it has to answer per frame rather than per arrival.
///
/// **A session's history does not fade at all.** Eighty rows fading up as a window opens reads as
/// the app being slow rather than as anything arriving, and it is not work turning up in front of
/// the reader, it is the pane being pointed somewhere else. That rule is `RowArrival.adopt` and
/// `TranscriptListView.arrivalSession`, which is a piece of bookkeeping rather than a decision, so
/// it is not restated here.
public enum TranscriptMotion {
    /// Whether a stored row of this kind is new on the frame it lands, and therefore worth fading.
    ///
    /// Prose and thinking are not. Both are streamed live first and stored afterwards, and the
    /// streaming views are lined up column for column with their stored twins precisely so that
    /// nothing moves when one replaces the other. Fading the stored row in would undo exactly
    /// that: the answer the reader is halfway through would go out and come back over a fifth of a
    /// second, which is the jump those columns exist to avoid.
    ///
    /// Nor is a user turn. The sentence is drawn from the queue the instant Return is pressed and
    /// the stored row replaces it in the same place at the same measure, so fading it in would
    /// take the owner's own message away and bring it back, which is the flicker the instant echo
    /// exists to remove.
    ///
    /// Everything else genuinely arrives.
    public static func fadesOnArrival(_ kind: MessageKind) -> Bool {
        switch kind {
        case .assistantText, .thinking, .user: false
        default: true
        }
    }

    // MARK: - Settling onto the screen

    /// How something that has only just turned up settles onto the screen.
    ///
    /// **Opacity paired with a small rise, rather than opacity alone.** Opacity on its own was
    /// filmed at 58 frames a second against a real streaming turn, and it is there and it is
    /// correct: eleven frames of monotonic ease out over 172ms. It is also 0.27 of one luminance
    /// level deep across the strip it lands in, against 8.65 for the ordinary stream delta that
    /// lands in the same strip half a second later. A settle a thirtieth the weight of the thing
    /// beside it is not a settle anybody sees. A few points of travel costs nothing per frame, it
    /// animates one more attribute of the same one-shot rather than adding a second animation,
    /// and it is what carries the sense of having arrived from somewhere.
    ///
    /// The rise is drawn rather than laid out: nothing below the row moves, nothing reflows, and
    /// the list never learns that anything happened. See `ArrivingRow`.
    ///
    /// Short, and only a little longer than the opacity-only settle it replaces. What is being
    /// marked is a row landing, which is a smaller event than a pane travelling, and a fifth of a
    /// second of it is the difference between reading as a settle and reading as an effect.
    public struct Arrival: Equatable, Sendable {
        /// How long the settle takes.
        public let seconds: Double

        /// How far below its resting place the content starts, in points.
        public let rise: Double
    }

    /// The settle a row or a block gets when it turns up, or nothing at all.
    ///
    /// Reduce Motion drops it rather than slowing it, which is what every other call site in this
    /// app does: the setting is about movement, and there is no slower version of this worth
    /// having. An absence rather than a zero, so that a caller cannot honour half of it. A caller
    /// that kept the zero opacity and dropped the curve would hide the row and never bring it
    /// back, which is exactly the bug the shape of this answer rules out.
    public static func arrival(reduceMotion: Bool) -> Arrival? {
        guard !reduceMotion else { return nil }
        return Arrival(seconds: 0.22, rise: 5)
    }

    // MARK: - Going back to the live end

    /// How the transcript travels when the reader asks to be taken back to the newest row.
    public enum LiveEndMove: Equatable, Sendable {
        /// There instantly, with no travel to watch. What Reduce Motion gets, and what a reader
        /// who is already at the end gets, since there is nowhere to go.
        case jump
        /// A short scroll, so the transcript arrives rather than teleports.
        case glide(seconds: Double)
    }

    /// The shortest a glide can be, which is what a small hop gets.
    ///
    /// The same fifth of a second the rest of the window answers a press in. See `Motion.pane`.
    public static let glideFloor: Double = 0.16

    /// The longest a glide can be, whatever the distance.
    ///
    /// **Nearly constant, and deliberately not proportional to the distance.** A reader who is
    /// five thousand points up is not asking for a tour of the conversation they scrolled past,
    /// they are asking to be at the end of it, and a scroll that took a second and a half to cover
    /// that would be an effect rather than a movement. What the travel is for is the sense of
    /// which way you went, and a quarter of a second of it carries that whether the distance was
    /// two hundred points or twenty thousand.
    public static let glideCeiling: Double = 0.26

    /// The distance at which a glide is already as long as it will ever be.
    ///
    /// Roughly two panes of a full height window. Past this the answer stops moving, which is the
    /// whole of the paragraph above.
    public static let glideRamp: Double = 1400

    /// Below this there is nothing worth animating: the reader is at the end already, or close
    /// enough to it that a curve would be a flicker rather than a movement. The same threshold
    /// `ScrollEnd` uses to decide whether the reader is following along, and for the same reason:
    /// there is one rule about how near the end counts as being at it, and this is not a second.
    public static let glideFloorDistance: Double = ScrollEnd.threshold

    /// How to travel to the live end.
    ///
    /// `distance` is how far below the viewport the end of the content is, and it is allowed to be
    /// a coarse number: the answer moves by a tenth of a second across the whole of its useful
    /// range, so the caller can quantise it hard enough that reporting it costs a scroll nothing.
    /// See `TranscriptGeometry`.
    ///
    /// Reduce Motion drops the movement rather than slowing it, which is what every other call
    /// site in this app does: the setting is about movement, and there is no slower version of
    /// this worth having.
    public static func liveEndMove(distance: Double, reduceMotion: Bool) -> LiveEndMove {
        guard !reduceMotion else { return .jump }
        guard distance >= glideFloorDistance else { return .jump }
        let ramp = min(1, max(0, distance) / glideRamp)
        return .glide(seconds: glideFloor + (glideCeiling - glideFloor) * ramp)
    }

    /// Whether arriving at the end has to be said a second time once the glide has finished.
    ///
    /// **Yes while a turn is streaming, and this is the one place the two mechanisms meet.** The
    /// end of the content is where it was when the glide was aimed at it, and a running turn moves
    /// it down by a line every few hundred milliseconds. So a glide during a turn lands a little
    /// short of the end it was pointed at, and short of the end is exactly the state in which the
    /// transcript does NOT follow the tail: the size-change anchor is only in force while the
    /// reader is near the bottom. Left alone, pressing the pill mid turn takes you to where the
    /// answer was and then leaves you behind again.
    ///
    /// Saying the edge again on arrival closes that gap and re-attaches the follow in one move.
    /// Not animated, because it is covering the two lines that arrived during the glide.
    ///
    /// A finished turn needs none of this. Nothing is growing, so the glide lands on the end.
    public static func reassertsLiveEnd(after move: LiveEndMove, isStreaming: Bool) -> Bool {
        switch move {
        case .jump: false
        case .glide: isStreaming
        }
    }
}
