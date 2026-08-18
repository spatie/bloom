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
        .headerMaterial()
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .stroke(Palette.border, lineWidth: Metrics.hairline)
        }
        .shadow(
            color: Palette.textPrimary.opacity(0.18),
            radius: Metrics.gutter,
            y: Metrics.corner
        )
    }
}
