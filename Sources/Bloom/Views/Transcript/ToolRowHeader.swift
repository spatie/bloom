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
                .transcriptLabelColumn()

            if showsDetail {
                Text(presentation.detail)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            // Deliberately not `fixedSize`: a row is one line tall and clips, so a chip that
            // refuses to give ground is cut in half at a narrow pane width rather than
            // truncated. `Chip` already holds itself to one line, and the detail beside it
            // carries the higher layout priority, so the chip only gives ground last.
            ForEach(Array(presentation.chips.enumerated()), id: \.offset) { _, chip in
                Chip(text: chip, monospaced: true)
            }

            Spacer(minLength: TranscriptLayout.tight)

            // Both of these are last in a row whose detail carries `layoutPriority`, so
            // without `fixedSize` the detail takes the slack and "error" wraps to "e" over "r"
            // inside a row that is one line tall by construction.
            if isError {
                Text("error")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
                    .fixedSize()
            }

            if let durationMS, durationMS > 0 {
                Text(TurnDuration.short(durationMS))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }

            TranscriptDisclosure(isExpanded: isExpanded, isVisible: isHovered)
        }
        .transcriptRowFrame()
    }
}
