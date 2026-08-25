import SwiftUI
import BloomCore

/// A quick prompt's mark, drawn whichever of the two kinds it turns out to be.
///
/// **An emoji is a full colour glyph and a symbol is a tinted one, and they do not share a size.**
/// A symbol set at thirteen points draws to about the cap height of thirteen point text; an emoji
/// at thirteen fills the whole em box and reads a size larger than everything around it. Set at
/// `emojiScale` of the symbol's size the two carry the same weight down a column of rows, which is
/// the only thing that matters here: the mark exists to tell one row from another at a glance, and
/// a column where every third mark is visibly bigger reads as a mistake rather than as a choice.
///
/// Both are then centred in the same square, which is what keeps the marks in one column rather
/// than in two that nearly agree. Centring rather than a shared baseline, because a `Text` box
/// carries descender room an `Image` does not, so two things sat on one baseline sit at two
/// different heights; `emojiRise` is what is left of that difference once the box is the same.
struct QuickPromptMarkView: View {
    /// The stored value, classified here rather than by the caller.
    var stored: String
    /// The point size a symbol is set at. The square both kinds are centred in is this wide.
    var points: CGFloat
    var tint: Color = Palette.textSecondary

    /// How much smaller an emoji is set than the symbol beside it. Measured off the gallery render
    /// rather than reasoned about: at 1.0 the emoji were plainly the larger mark, and at
    /// 0.82 the bug in the list read a size under the seal above it.
    private static let emojiScale: CGFloat = 0.86
    /// A `Text` box reserves room under the baseline for descenders and an emoji uses none of it,
    /// so a centred emoji sits that much high. This puts it back down.
    private static let emojiRise: CGFloat = 0.06

    /// Fixed rather than scaled with `\.fontScale`, like `Metrics.repoIcon` and every other mark in
    /// the window: the box it sits in is a layout number, and a glyph that grew inside a box that
    /// did not would only overflow it.
    var body: some View {
        Group {
            switch QuickPromptMark(stored: stored) {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: points))
                    .foregroundStyle(tint)
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: points * Self.emojiScale))
                    // No tint. Colouring an emoji does nothing on macOS, and asking for it would
                    // only suggest to the next reader that it might.
                    .offset(y: points * Self.emojiRise)
            }
        }
        .frame(width: points, height: points)
    }
}
