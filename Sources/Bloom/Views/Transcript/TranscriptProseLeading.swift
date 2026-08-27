import AppKit
import SwiftUI
import BloomCore

/// The transcript's leading, resolved against the size and the face the conversation is actually
/// set in.
///
/// **Its own file because it is the one piece of `TranscriptLayout` that is not a number.** Every
/// other value there is a constant the whole window agrees on; this one has to ask AppKit how tall
/// a line of a particular font is before it can answer, which brings a font cache and a view
/// modifier with it, and none of that is what a reader opens `TranscriptLayout` to find.
///
/// The rule it applies is `TextLeading` in the core, where the two ratios and the reason there are
/// two of them are written down. What is here is only how a view reaches it: the rung, the scale
/// and the face come out of the environment, and the line box comes out of the font they resolve
/// to.
extension TranscriptLayout {
    /// Extra leading for a run of prose set on `rung`, so the line height holds at
    /// `TextLeading.proseRatio` whatever size the conversation is set at.
    ///
    /// **A fixed number of points is a different line height at every text size, which is how this
    /// came to be wrong at the default in the first place.** Three points on the sixteen point
    /// line box thirteen point prose is laid out in read as 1.46; the same three points at the
    /// largest step, twenty points in a box of twenty three, read as 1.30. So the setting that
    /// exists to make the conversation easier to read was quietly tightening it. It now answers
    /// five, six, eight, nine and eleven points across those five steps, for 1.67 to 1.73.
    ///
    /// The rung is asked for rather than assumed, because the two thinking rows draw their prose
    /// at `Typo.label` and a paragraph led for thirteen points is too airy for twelve. What a
    /// caller must not do is pass a rung the run is not actually set in: see `MarkdownView`, which
    /// leads a whole markdown block from `Typo.body` because that is what the block was handed.
    @MainActor
    static func proseLeading(_ rung: ScaledFont, scale: CGFloat, face: ChatFont) -> CGFloat {
        let font = rung.resolvedNSFont(scale: scale, face: face)
        return CGFloat(TextLeading.overPointSize(
            lineHeight: Double(lineBox(of: font)), pointSize: Double(font.pointSize)
        ))
    }

    /// Extra leading for a block of code that wraps, which is the permission panel's command.
    ///
    /// A separate decision from prose and it stays one: the argument for it is that a wrapped
    /// shell command has no sentence shape to fall back on and the eye has to find the start of
    /// the next line by position alone, which is a different reason from wanting a paragraph to
    /// breathe. See `TextLeading.codeRatio`, which holds the number that argument arrived at.
    ///
    /// It became a ratio for the same reason prose did and for no other. It used to be
    /// `Metrics.spacingSmall`, and losing the spacing scale is the price: a command at the largest
    /// chat step was set at 1.20 of its line box where the panel at the default was set at 1.31,
    /// so the block that must be read most carefully was the one set tightest for the reader who
    /// had asked for larger text. At the default this still answers four points.
    @MainActor
    static func codeLeading(_ rung: ScaledFont, scale: CGFloat, face: ChatFont) -> CGFloat {
        CGFloat(TextLeading.overLineBox(
            lineHeight: Double(lineBox(of: rung.resolvedNSFont(scale: scale, face: face)))
        ))
    }

    /// How tall one line of this font is laid out at, before anything is added to it.
    ///
    /// `NSLayoutManager`'s answer rather than `ascender - descender + leading`, because it is the
    /// number the transcript's own `NSTextView` prose is really laid out with and the two must not
    /// disagree about the same paragraph. Measured on this machine it is also SwiftUI's own line
    /// pitch for a system font at every size the conversation offers but two, where it is a point
    /// short of it; that point predates this and is not something a leading can fix.
    ///
    /// Held, because it is asked once per run of prose per pass and a transcript is tens of
    /// thousands of those, where a fresh `NSLayoutManager` per ask is an allocation and a
    /// dictionary lookup is not. Keyed on the font, so a change of size or face misses.
    ///
    /// It needs no bound and cannot grow into one. What can be put in it is the rungs of `Typo`
    /// crossed with the five steps of `ChatTextSize` and the four faces of `ChatFont`, which is
    /// under two hundred entries and is reached in the first minute of reading a conversation.
    @MainActor
    private static func lineBox(of font: NSFont) -> CGFloat {
        if let held = lineBoxes[font] { return held }
        let measured = leadingLayout.defaultLineHeight(for: font)
        lineBoxes[font] = measured
        return measured
    }

    @MainActor private static var lineBoxes: [NSFont: CGFloat] = [:]
    @MainActor private static let leadingLayout = NSLayoutManager()
}

extension View {
    /// Leads a run of transcript prose from the size the conversation is set at.
    ///
    /// Overloads nothing and hides nothing: it is `lineSpacing` with the number worked out from
    /// the environment the text is actually in, which is the same shape `ScaledFont`'s own
    /// modifier takes and for the same reason. A call site says which rung it set the run in and
    /// learns nothing else.
    func proseLeading(_ rung: ScaledFont = Typo.body) -> some View {
        modifier(ProseLeadingModifier(rung: rung))
    }
}

private struct ProseLeadingModifier: ViewModifier {
    let rung: ScaledFont

    @Environment(\.fontScale) private var scale
    @Environment(\.chatFont) private var face

    func body(content: Content) -> some View {
        content.lineSpacing(TranscriptLayout.proseLeading(rung, scale: scale, face: face))
    }
}
