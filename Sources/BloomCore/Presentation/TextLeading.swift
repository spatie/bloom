import Foundation

/// How much air a line of transcript text is given on top of the line box its font already asks
/// for.
///
/// **Here rather than beside the views because it is arithmetic, and arithmetic in a view is
/// arithmetic nothing can test.** What it produces is a number handed to `lineSpacing`, which is
/// what SwiftUI and TextKit both call the gap BETWEEN two line boxes, so every answer below is an
/// extra rather than a total.
///
/// The owner put an agent's generated HTML page next to Bloom's own transcript and asked for the
/// page's line height in the chat. The page set its prose at about 1.7; the transcript was three
/// fixed points on top of whatever line box the font had, which at the default chat size came to
/// about 1.46 and, because it was fixed, to something different at every other size the reader can
/// choose. That is the whole reason a ratio is worked out here instead of a constant being picked.
///
/// **The two ratios below are measured against different things, and that is deliberate rather
/// than an oversight.** Prose is stated the way every stylesheet states it, as a multiple of the
/// point size, because that is the number the page the owner was looking at was set with and the
/// number anybody comparing the two would reach for. Code is stated as a multiple of the line box,
/// because that is how its own argument was written down when it was decided, and restating it
/// against the point size would silently change what was agreed. Two denominators, two functions,
/// and nothing shared between them but this file.
public enum TextLeading {
    /// What a line of prose comes to, as a multiple of the size it is set at, when the reader has
    /// not said otherwise.
    ///
    /// 1.7, from the page the owner asked for. It is also where the readability advice sits for a
    /// column of this measure: the WCAG 1.4.12 floor is 1.5, and the range typography guides give
    /// for body text on a screen is 1.5 to 1.8, so 1.7 is the generous end of that rather than a
    /// number past it. The transcript is the one surface in the window that is read a line at a
    /// time instead of scanned, which is why it gets the generous end and nothing else does.
    ///
    /// It is `ChatLineHeight.standard.ratio` rather than a literal, because the owner then asked
    /// for the line height to be a setting and 1.7 became the middle of five. Two places saying
    /// 1.7 is one place that can be moved and one that will not be, and this is the one every
    /// caller that has no reader to ask reaches for.
    public static let proseRatio: Double = ChatLineHeight.standard.ratio

    /// What a line of wrapped code comes to, as a multiple of its own line box.
    ///
    /// 1.3, which is the number `TranscriptLayout.codeLeading` was already set at and is stated
    /// here in the terms its argument used: four points on a thirteen point line box. Holding it
    /// as a ratio is the only change, and at the default chat size it lands back on the same four
    /// points it has always been.
    public static let codeRatio: Double = 1.3

    /// Extra leading that brings a line to `ratio` times the size it is set at.
    ///
    /// Rounded to a whole point, because a transcript row's height is measured, rounded up and
    /// cached, and a fractional gap repeated down a paragraph is a fraction of a point of jitter
    /// per row for nothing anybody can see. Never negative: a font whose line box is already
    /// taller than the ratio asks for is left alone rather than crushed.
    public static func overPointSize(
        lineHeight: Double, pointSize: Double, ratio: Double = proseRatio
    ) -> Double {
        guard lineHeight > 0, pointSize > 0 else { return 0 }
        return max(0, (ratio * pointSize - lineHeight).rounded())
    }

    /// Extra leading that brings a line to `ratio` times its own line box. See `codeRatio` for why
    /// this one is measured against the box and prose is not.
    public static func overLineBox(lineHeight: Double, ratio: Double = codeRatio) -> Double {
        guard lineHeight > 0 else { return 0 }
        return max(0, (ratio * lineHeight - lineHeight).rounded())
    }
}
