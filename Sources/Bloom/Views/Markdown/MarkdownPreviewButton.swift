import SwiftUI

struct MarkdownPreviewButton: View {
    let isPresented: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isPresented ? "Back" : "Preview", systemImage: isPresented ? "arrow.left" : "doc.richtext")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .foregroundStyle(isPresented ? Palette.accent : Palette.textSecondary)
        .help(isPresented ? "Return to the file" : "Show Markdown preview")
        .accessibilityLabel(isPresented ? "Return to the file" : "Show Markdown preview")
    }
}
