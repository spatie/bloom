import SwiftUI

/// The file or URL an expanded row is about. Truncated in the middle, because both ends of a path
/// carry more than its centre does.
struct DetailPathLabel: View {
    var path: String

    var body: some View {
        Text(path)
            .font(Typo.codeSmall)
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
