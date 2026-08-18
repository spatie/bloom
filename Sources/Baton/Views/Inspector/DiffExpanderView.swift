import SwiftUI

/// The affordance that reveals context a diff hid.
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
                Text(title)
                    .font(Typo.codeTiny)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovered ? Palette.accent : Palette.textTertiary)
            .padding(.horizontal, CodeMetrics.textInset)
            .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
            .background(isHovered ? Palette.hover : Palette.surfaceSunken)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
