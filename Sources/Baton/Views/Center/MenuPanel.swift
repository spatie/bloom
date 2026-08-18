import SwiftUI

/// The floating card both composer menus sit in. One definition so the slash menu and the file
/// menu cannot drift apart.
struct MenuPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The panel floats outside the composer, so it must size itself from its rows rather than
        // from the space the composer happens to occupy.
        .fixedSize(horizontal: false, vertical: true)
        // The menu material, not the header material this used to borrow. `.headerView` is the
        // vibrancy of a toolbar strip; a thing that floats over content is a menu and reads wrong
        // in anything else.
        .background(VisualEffectBackground(material: .menu, blending: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
        // Black, not the label colour: a shadow tinted with `labelColor` turns into a white glow
        // in dark mode, which is the opposite of what a shadow is for.
        .shadow(
            color: .black.opacity(0.24),
            radius: Metrics.gutter,
            y: Metrics.spacingSmall
        )
    }
}
