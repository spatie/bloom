import SwiftUI

/// The labels in the composer footer are all the same shape: a mark, a word, and a hint that it
/// opens. Defining it once is what keeps the row on one height, one font and one baseline.
///
/// The height is pinned rather than derived from the label, because the footer mixes a menu, two
/// toggles and a send button, and every one of those sizes itself differently when left alone.
///
/// The mark is a slot rather than an SF Symbol name so the create window's project control can put
/// a `RepoIcon` in it and still be the same control as the pickers beside it. Everything that
/// names an SF Symbol goes through the convenience initialiser below and reads exactly as it did.
struct ComposerControlLabel<Icon: View>: View {
    /// Nil for the icon-only controls, so an attach button is exactly as tall as it is wide and
    /// still lines up with the pickers beside it.
    var text: String?
    var tint: Color = Palette.textSecondary
    var isActive: Bool = false
    /// Drawn here rather than by the menu style. `.menuStyle(.borderlessButton)` clamps whatever
    /// it is given to sixteen points, which is what left the pickers a whole row shorter than the
    /// buttons next to them.
    var showsMenuIndicator: Bool = false
    @ViewBuilder var icon: Icon

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            icon
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

extension ComposerControlLabel where Icon == Image {
    init(
        systemImage: String,
        text: String?,
        tint: Color = Palette.textSecondary,
        isActive: Bool = false,
        showsMenuIndicator: Bool = false
    ) {
        self.init(
            text: text,
            tint: tint,
            isActive: isActive,
            showsMenuIndicator: showsMenuIndicator,
            icon: { Image(systemName: systemImage) }
        )
    }
}
