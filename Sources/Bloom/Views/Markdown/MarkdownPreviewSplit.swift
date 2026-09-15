import SwiftUI

/// Keep the source at one view identity when the preview opens, preserving selection and undo.
struct MarkdownPreviewSplit<Content: View>: View {
    let path: String
    let revision: Int
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    @State private var previewWidth: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let available = max(0, Double(proxy.size.width - Metrics.spacingWide))
            let minimum = min(180, available / 2)
            let bounds = minimum...max(minimum, available - minimum)
            let width = (previewWidth == 0 ? available / 2 : previewWidth).clamped(to: bounds)
            HStack(spacing: 0) {
                content()
                    .frame(width: isPresented ? available - width : proxy.size.width)
                    .frame(maxHeight: .infinity)
                    .clipped()
                if isPresented {
                    PaneDivider(
                        axis: .horizontal,
                        length: Binding(get: { width }, set: { previewWidth = $0 }),
                        bounds: bounds, reset: available / 2, label: "Markdown preview width"
                    )
                    MarkdownFilePreview(path: path, revision: revision) { isPresented = false }
                        .frame(width: width)
                        .clipped()
                }
            }
        }
    }
}
