import SwiftUI

/// The leading glyph of any row.
///
/// It exists so every row type draws its symbol at one size, in one column width. Symbols have
/// wildly different intrinsic widths, and letting each row pick its own point size is what makes a
/// dense list look ragged down its left edge.
struct TranscriptGlyph: View {
    var symbol: String
    var tint: Color = Palette.textTertiary

    var body: some View {
        Image(systemName: symbol)
            .font(Typo.label)
            .imageScale(.small)
            .foregroundStyle(tint)
            .frame(width: TranscriptLayout.glyphWidth, alignment: .center)
            // The row's own text says what the row is. The glyph repeating it is noise in VoiceOver.
            .accessibilityHidden(true)
    }
}
