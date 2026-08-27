import SwiftUI

private struct TranscriptFoldCountKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var transcriptFoldCount: Int? {
        get { self[TranscriptFoldCountKey.self] }
        set { self[TranscriptFoldCountKey.self] = newValue }
    }
}

/// The leading glyph of any row.
///
/// It exists so every row type draws its symbol at one size, in one column width. Symbols have
/// wildly different intrinsic widths, and letting each row pick its own point size is what makes a
/// dense list look ragged down its left edge.
struct TranscriptGlyph: View {
    var symbol: String
    var tint: Color = Palette.textTertiary
    @Environment(\.transcriptFoldCount) private var foldCount

    var body: some View {
        Group {
            if let foldCount {
                Text(foldCount, format: .number)
                    .font(Typo.micro)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.white)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 19, height: 19)
                    .background(Palette.textTertiary, in: Circle())
            } else {
                Image(systemName: symbol)
                    .font(Typo.label)
                    .imageScale(.small)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: TranscriptLayout.glyphWidth, alignment: .center)
        // The row's own text says what the row is. The glyph repeating it is noise in VoiceOver.
        .accessibilityHidden(true)
    }
}
