import SwiftUI

/// The file or URL an expanded row is about. Truncated in the middle, because both ends of a path
/// carry more than its centre does.
struct DetailPathLabel: View {
    var path: String

    var body: some View {
        Text(path)
            .font(Typo.codeSmall)
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            // The middle is what was dropped, so the tooltip is the only way back to it.
            .help(path)
    }
}
