import SwiftUI

/// One file the turn touched, with what it did to it.
struct TurnFileChip: View {
    var file: TurnFile

    var body: some View {
        HStack(spacing: TranscriptLayout.tight * 2) {
            Text(file.name)
                // The rung `Chip` uses, because a real `Chip` sits beside this one in the same
                // footer whenever a turn touched more files than fit.
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)

            DiffStatLabel(additions: file.additions, deletions: file.deletions, compact: true)
        }
        .padding(.horizontal, TranscriptLayout.chipInset)
        .padding(.vertical, Metrics.chipInsetV)
        .background(Palette.hover, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .help(file.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.path)
    }
}
