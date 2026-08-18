import SwiftUI

/// The labels in the composer footer are all the same shape: a glyph, a word, and a hint that it
/// opens. Defining it once is what keeps the row on one height, one font and one baseline.
///
/// The height is pinned rather than derived from the label, because the footer mixes a menu, two
/// toggles and a send button, and every one of those sizes itself differently when left alone.
struct ComposerControlLabel: View {
    var systemImage: String
    /// Nil for the icon-only controls, so an attach button is exactly as tall as it is wide and
    /// still lines up with the pickers beside it.
    var text: String?
    var tint: Color = Palette.textSecondary
    var isActive: Bool = false
    /// Drawn here rather than by the menu style. `.menuStyle(.borderlessButton)` clamps whatever
    /// it is given to sixteen points, which is what left the pickers a whole row shorter than the
    /// buttons next to them.
    var showsMenuIndicator: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Image(systemName: systemImage)
                .imageScale(.small)

            if let text {
                Text(text).lineLimit(1)
            }

            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .font(Typo.label)
        .foregroundStyle(tint)
        .padding(.horizontal, text == nil ? 0 : Metrics.spacing)
        .frame(minWidth: Metrics.rowHeight, minHeight: Metrics.rowHeight)
        .frame(height: Metrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(isActive ? Palette.selected : (isHovered ? Palette.hover : .clear))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
