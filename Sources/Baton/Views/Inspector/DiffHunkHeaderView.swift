import SwiftUI

/// The `@@` line, showing the enclosing function git found. Quiet, because it is orientation
/// rather than content.
struct DiffHunkHeaderView: View {
    var text: String
    var width: CGFloat

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            Image(systemName: "arrow.left.and.right")
                .font(Typo.micro)
                .imageScale(.small)
            Text(text)
                .font(Typo.codeTiny)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, CodeMetrics.textInset)
        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
        .background(Palette.surfaceSunken)
    }
}
