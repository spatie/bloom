import SwiftUI
import BloomClient

public struct BloomChangeBadge: View {
    private let change: ChangedFile.Change
    @Environment(\.colorScheme) private var scheme
    public init(change: ChangedFile.Change) { self.change = change }

    public var body: some View {
        Text(change.rawValue)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(colour)
            .frame(minWidth: 22, minHeight: 22)
            .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(description)
    }

    private var colour: Color {
        let pair = switch change {
        case .added, .untracked: PaletteInk.accent
        case .deleted: PaletteInk.negative
        case .modified: PaletteInk.warning
        case .renamed, .copied: PaletteInk.accentFill
        }
        return BloomColour.resolve(pair, scheme: scheme)
    }

    private var description: String {
        switch change {
        case .added: "Added"
        case .untracked: "Untracked"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .copied: "Copied"
        }
    }
}
