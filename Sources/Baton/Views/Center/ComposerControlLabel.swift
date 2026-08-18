import SwiftUI

/// The labels in the composer footer are all the same shape: a glyph, a word, and a hint that it
/// opens. Defining it once keeps them on one baseline.
struct ComposerControlLabel: View {
    var systemImage: String
    var text: String
    var tint: Color = Palette.textSecondary
    var isActive: Bool = false

    @State private var isHovered = false

    var body: some View {
        Label {
            Text(text)
                .font(Typo.caption)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .font(Typo.micro)
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(tint)
        .padding(.horizontal, Metrics.corner)
        .frame(height: Metrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(isActive ? Palette.selected : (isHovered ? Palette.hover : .clear))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
