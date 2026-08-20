import SwiftUI
import BloomCore

extension PullRequestStatus.Tone {
    /// The palette colour a tone resolves to, or nil for the neutral one.
    ///
    /// Nil rather than grey, so a pull request with nothing to report leaves a plain strip instead
    /// of a wash that looks like a state. Shared by the bar's background and the parts drawn on
    /// it, which is the point of it living here: the sentence, the chip and the merge button all
    /// have to land on the same colour or the strip reads as three unrelated things.
    ///
    /// This is the INK value: a headline, a badge rim, a menu's chevron, and the bar's own wash of
    /// itself. Anything that fills a control and puts white text on it takes `fill` instead.
    var color: Color? {
        switch self {
        case .neutral: nil
        case .positive: Palette.positive
        case .negative: Palette.negative
        case .warning: Palette.warning
        case .merged: Palette.merged
        }
    }

    /// The colour of the one prominent button in this state.
    ///
    /// It exists so the answer is given once. Every filled control in the strip used to spell out
    /// `tint ?? Palette.accentFill` for itself: three call sites agreeing by hand about something
    /// the tone already knows, and a fourth state added tomorrow would have had to remember. The
    /// rule is that the prominent button carries the colour of the band it stands in, because a
    /// blue button in an amber band says the strip is two decisions rather than one, and a rule
    /// stated in three places is a rule waiting to be broken in one of them.
    ///
    /// Never optional, because there is always a button to paint. The neutral tone has no colour
    /// of its own by design, and it has no band either, so it falls back to the app's own
    /// prominent fill: Draft and Closed are the only states where the button is not the band's
    /// colour, and in both the band is the bare surface.
    ///
    /// `merged` is the one tone whose fill is not its ink. `Palette.merged` is a pair tuned for
    /// ink on each ground, and white on its dark member measures 3.35 to 1, under the floor for a
    /// button label; `Palette.mergedFill` holds the light member in both appearances and measures
    /// 5.05. The other tones hand back their own colour unchanged, which is what they drew before
    /// this existed.
    var fill: Color {
        switch self {
        case .merged: Palette.mergedFill
        default: color ?? Palette.accentFill
        }
    }
}
