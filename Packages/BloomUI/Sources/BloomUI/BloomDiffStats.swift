import SwiftUI
import BloomClient

/// Compact textual counts remain understandable without their green and red colours.
public struct BloomDiffStats: View {
    private let additions: Int
    private let deletions: Int
    private let isBinary: Bool
    @Environment(\.colorScheme) private var scheme

    public init(additions: Int, deletions: Int, isBinary: Bool = false) {
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }

    public var body: some View {
        HStack(spacing: 6) {
            if isBinary {
                Text("Binary").foregroundStyle(.secondary)
            } else {
                Text("+\(additions)").foregroundStyle(BloomColour.resolve(PaletteInk.accent, scheme: scheme))
                Text("-\(deletions)").foregroundStyle(BloomColour.resolve(PaletteInk.negative, scheme: scheme))
            }
        }
        .font(.caption.monospacedDigit())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isBinary ? "Binary file" : "\(additions) additions, \(deletions) deletions")
    }
}
