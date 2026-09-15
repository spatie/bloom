import SwiftUI

struct MarkdownPreviewButton: View {
    let isPresented: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Preview", systemImage: "doc.richtext")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .foregroundStyle(isPresented ? Palette.accent : Palette.textSecondary)
        .help(isPresented ? "Close Markdown preview" : "Open Markdown preview to the side")
        .accessibilityLabel(isPresented ? "Close Markdown preview" : "Open Markdown preview to the side")
    }
}
