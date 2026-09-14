import SwiftUI
import BloomCore

/// Owns preference observation even when the surrounding equatable row skips an update.
struct FileTreeIcon: View {
    let name: String
    let isDirectory: Bool
    let isExpanded: Bool
    @AppStorage(VSCodeIconsInstaller.defaultsKey) private var enabled = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            if isDirectory {
                Image(systemName: "chevron.right")
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(TreeDisclosureMotion.chevron(reduceMotion: reduceMotion).animation, value: isExpanded)
                    .frame(width: InspectorLayout.glyphWidth, alignment: .leading)
            }
            if enabled, let image = FileIconThemeModel.shared.image(
                name: name, isDirectory: isDirectory, expanded: isExpanded, isLight: colorScheme == .light
            ) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: InspectorLayout.glyphWidth, height: InspectorLayout.glyphWidth)
            } else if !isDirectory {
                Image(systemName: "doc")
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .frame(width: InspectorLayout.glyphWidth, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
        .task(id: enabled) {
            if enabled { await FileIconThemeModel.shared.load() }
        }
    }
}
