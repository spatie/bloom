import SwiftUI

/// The affordance that reveals context a diff hid.
///
/// **It has to say it is pressable while nothing is on it.** At rest this band was identical to
/// `DiffHunkHeaderView`, which is inert: the same ground, height, rung, ink and inset, with only
/// the symbol differing, and the difference only appeared once the pointer was already on it.
/// A reader scrolling a diff has no reason to try one band and not the other. So the chevrons are
/// drawn in the accent at rest and the words are not, which marks the row as a control without
/// putting a coloured sentence on every collapsed run in the file.
struct DiffExpanderView: View {
    var title: String
    var width: CGFloat
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InspectorLayout.gap) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Typo.micro)
                    .imageScale(.small)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Typo.codeTiny)
                    .foregroundStyle(isHovered ? Palette.accent : Palette.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CodeMetrics.textInset)
            .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
            // The hover tint is a translucent wash, so it goes OVER the band's own fill. Swapped
            // for it, hovering made the strip lighter than its resting state instead of darker.
            .background(isHovered ? Palette.hover : .clear)
            .background(Palette.surfaceSunken)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
