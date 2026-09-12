import Foundation
import BloomClient

/// Whether a stored row is going to draw anything at all, answered from the row rather than from a
/// laid out view.
///
/// **Sixty per cent of a real session draws nothing.** Measured on an 1,855 row conversation and
/// again on a 2,981 row one: 1,804 of the latter are `system` stream events, and a `system` row
/// that is not an init draws no view at all. They are ordinary rows in the table, three to five of
/// them between every pair of tool calls, and until something has drawn one there is nothing to
/// tell the table but the running mean of the rows that HAVE been drawn.
///
/// That is what put a hundred points of blank between two one line Bash rows, and the correction
/// for it is what makes scrolling upwards expensive: a screen of rows nobody has drawn is a screen
/// of guesses, every one of which is put right a frame later and moves everything below it. The
/// guess can simply be right instead. See `TranscriptRowHeights.assumed`.
///
/// **A sniff rather than a decode, for the reason `TranscriptNoise` gives.** Deciding this by
/// decoding the payload would be the whole cost this exists to avoid, once per row on the pass
/// that assembles the entries. The first bytes are enough to tell the two apart.
///
/// It is a claim about what the row will draw, not a promise. A row that draws something after all
/// reports its height when it is drawn and is corrected then, exactly as any other estimate is, so
/// being wrong here costs one correction rather than a wrong transcript.
public enum TranscriptRowInk {
    public static func drawsNothing(kind: MessageKind, payload: Data) -> Bool {
        TranscriptVisibility.systemDrawsNothing(kind: kind.rawValue, payload: payload)
    }
}
