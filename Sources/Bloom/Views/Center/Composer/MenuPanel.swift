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
        // Clipped before the glass rather than after it. `glassEffect` shapes only its own
        // background, so a selected row's fill and the scroll view still need this to stop at the
        // corner.
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        // macOS 26's material, not `NSVisualEffectView(.menu)`. `ComposerOptionMenu` is a real
        // `Menu` an inch away in the same footer and the system draws it in glass, so the footer
        // was showing two menus in two generations of material.
        //
        // `.regular` and not `.clear`: this opens over the transcript, where a user bubble is
        // `Palette.accentFill`, and clear glass carries that through. See `JumpToNewestPill`.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.corner))
        // The rim is drawn rather than left to glass's own, because it is what still says where
        // the card ends once Reduce Transparency has turned the material opaque.
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
        // A panel open over the window is `lifted`, and the recipe is `Elevation`'s rather than
        // this file's: the three shadows in the app were three unrelated numbers, including the
        // "black, not the label colour" argument written out three times.
        .elevation(.lifted)
    }
}
