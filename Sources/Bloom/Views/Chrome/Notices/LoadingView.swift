import SwiftUI

/// Gives short background work a quiet, reusable treatment that does not dominate dense panes.
struct LoadingView: View {
    let label: String?

    init(_ label: String? = nil) {
        self.label = label
    }

    var body: some View {
        // `spacingWide` rather than `gutter`, because this is a glyph and its label and not two
        // groups of a row. It is the same rung the transcript spends on every one of its glyph
        // columns, where it is called `TranscriptLayout.glyphGap`. At the gutter the pair measured
        // thirteen points of daylight off a window capture, which is not a number anywhere in the
        // scale: it was the gutter's twelve plus whatever the spinner and the first letter keep
        // inside their own boxes.
        //
        // Centred, and deliberately NOT `.firstTextBaseline`, which is what `AgentQuestionCard`
        // and every other glyph beside a label in this window aligns on. A spinner is not a glyph:
        // it has no baseline of its own, so SwiftUI answers with the bottom edge of its box, which
        // would stand the whole ring above the words with its centre nearly four points clear of
        // theirs. Centring is right here and it is not a guess: `NSProgressIndicator` draws the
        // ring centred in its box at all three control sizes, measured into a bitmap, and the
        // system font's line box is centred on its own cap height to within a third of a point
        // (callout: ascender 11.6, descender 2.53, leading 0.87, cap 8.46). So the two boxes
        // agreeing is the two things a reader sees agreeing.
        HStack(spacing: Metrics.spacingWide) {
            ProgressView()
                // The size of the words beside it, rather than the size AppKit hands out.
                //
                // `ProgressView()` at the default control size is the regular spinner, which is 32
                // points square. That is `NSProgressIndicator.intrinsicContentSize`, and it is the
                // first of the three sizes `StatusColumnGallery` already writes down (32, 16, 10).
                // The label it is introducing is `Typo.label`, whose line box is 15 points, so the
                // spinner stood over twice the height of its own sentence and read as a control a
                // line of text happened to be sitting next to. `.small` is a 16 point indicator,
                // which is that line box, and it is what every other spinner in this window
                // already asks for: `.small` in the setup sheet, the sign in sheet and the create
                // window, `.mini` in the sidebar's status column. This one was the exception, and
                // it is the only spinner drawn against a pane rather than inside a row, which is
                // how it kept the default without anybody noticing.
                .controlSize(.small)

            if let label {
                Text(label)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        // One announcement rather than "progress indicator" followed by a stray sentence.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "Loading")
    }
}
