import SwiftUI

/// The single line a tool call occupies while it is closed: what it did, to what, and how long it
/// took, on the columns every other row uses.
struct ToolRowHeader: View {
    var presentation: ToolPresentation
    var isError: Bool
    var durationMS: Int?
    var isExpanded: Bool
    var isHovered: Bool

    /// A chip that repeats the detail replaces it: `Read [notes.txt]` rather than
    /// `Read notes.txt [notes.txt]`.
    private var showsDetail: Bool {
        !presentation.detail.isEmpty && !presentation.chips.contains(presentation.detail)
    }

    var body: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(
                symbol: presentation.glyph,
                tint: isError ? Palette.negative : presentation.tint
            )

            Text(presentation.label)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TranscriptLayout.labelWidth, alignment: .leading)

            if showsDetail {
                Text(presentation.detail)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            ForEach(Array(presentation.chips.enumerated()), id: \.offset) { _, chip in
                Chip(text: chip, monospaced: true)
                    .fixedSize()
            }

            Spacer(minLength: TranscriptLayout.tight)

            if isError {
                Text("error")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.negative)
            }

            if let durationMS, durationMS > 0 {
                Text(TurnDuration.short(durationMS))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
            }

            TranscriptDisclosure(isExpanded: isExpanded, isVisible: isHovered)
        }
        .transcriptRowFrame()
    }
}
