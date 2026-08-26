import SwiftUI

/// Reasoning as it arrives.
///
/// Streaming thinking is a scroll of consciousness. Only the tail is interesting, and only the tail
/// is cheap: laying out a hundred kilobytes of italic text on every delta is not something a
/// transcript can afford.
///
/// The header is deliberately the same shape, the same columns and the same colours as
/// `ThinkingRowView`, because the stored row replaces this one mid sentence and anything that
/// disagrees shows up as a jump.
struct StreamingThinkingView: View {
    var text: String
    var tokens: Int

    private static let tailLimit = 600

    /// The last 600 characters, with a leading ellipsis only when something was really dropped.
    ///
    /// The byte count is a cheap upper bound and nothing more: a string of n bytes can never hold
    /// more than n characters, so anything at or under the limit in bytes is under it in
    /// characters too and needs no walk at all. That is the fast path, it is the common one, and
    /// it is why this is not `text.count`, which walks a buffer the file's own header says reaches
    /// a hundred kilobytes, on every delta.
    ///
    /// **It cannot decide the cut, only skip it.** Four hundred accented or CJK characters are
    /// over 600 bytes and under 600 characters, so the byte test alone sent complete text down the
    /// else branch, where `suffix` returned all of it and an ellipsis was prefixed to text nothing
    /// had been taken from. Comparing the indices says whether the cut moved, in constant time.
    private var tail: String {
        guard text.utf8.count > Self.tailLimit else { return text }
        let kept = text.suffix(Self.tailLimit)
        guard kept.startIndex != text.startIndex else { return text }
        return "\u{2026}" + String(kept)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text(tail)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .italic()
                .lineSpacing(TranscriptLayout.proseLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TranscriptLayout.detailIndent)
                .padding(.trailing, TranscriptLayout.inset)
                .padding(.bottom, TranscriptLayout.block)
        }
    }

    private var header: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "sparkle")

            Text("Thinking")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .italic()
                .lineLimit(1)
                .transcriptLabelColumn("Thinking", font: Typo.label)

            if tokens > 0 {
                Text("\(tokens) tokens")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }

            Spacer(minLength: TranscriptLayout.tight)
        }
        .transcriptRowFrame()
    }
}
