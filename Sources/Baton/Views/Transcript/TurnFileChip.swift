import SwiftUI

/// One file the turn touched, with what it did to it.
struct TurnFileChip: View {
    var file: TurnFile

    var body: some View {
        HStack(spacing: TranscriptLayout.tight * 2) {
            Text(file.name)
                .font(Typo.codeTiny)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)

            DiffStatLabel(additions: file.additions, deletions: file.deletions, compact: true)
        }
        .padding(.horizontal, TranscriptLayout.inset - 1)
        .padding(.vertical, TranscriptLayout.tight)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .help(file.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.path)
    }
}
