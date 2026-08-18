import SwiftUI
import BatonCore

/// The containing folder as a chip, then the bare filename.
///
/// Two weights rather than one long path, because the only part of a path anybody reads first is
/// the last component. The folder is there to answer "which of the four `Handler.php` files is
/// this", so it is quiet, capped, and the first thing to give up room when the pane narrows.
struct FilePathChip: View {
    var file: ChangedFile
    /// Shown when Edit mode is holding changes that are not on disk yet.
    var hasUnsavedEdits: Bool

    /// Enough for two or three path components. Past that the chip is competing with the name.
    private static let chipWidth: CGFloat = 170

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            if !file.directory.isEmpty {
                Text(file.directory)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Palette.hover, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    )
                    .frame(maxWidth: Self.chipWidth, alignment: .leading)
                    // The chip is the first thing to give up room, because the brief of the bar
                    // is that the filename reads in full and the folder is only there to
                    // disambiguate it.
                    .layoutPriority(-1)
            }

            Text(file.filename)
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            if hasUnsavedEdits {
                Circle()
                    .fill(Palette.accent)
                    .frame(width: Metrics.dot, height: Metrics.dot)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
        }
        .help(file.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.path)
    }
}
