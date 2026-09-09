import SwiftUI
import BloomClient

/// Narrow inspectors give the filename its own line before spending width on counts.
public struct BloomChangedFileName: View {
    private let file: ChangedFile
    public init(file: ChangedFile) { self.file = file }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: file.filename)
                .font(.body)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(file.path)
            HStack(spacing: 8) {
                let directory = (file.path as NSString).deletingLastPathComponent
                if !directory.isEmpty {
                    Text(verbatim: directory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                BloomDiffStats(additions: file.additions, deletions: file.deletions, isBinary: file.isBinary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
