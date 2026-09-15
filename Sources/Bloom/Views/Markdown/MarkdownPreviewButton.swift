import SwiftUI

struct MarkdownPreviewButton: View {
    let isPresented: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if isPresented {
                Text(verbatim: "<>")
                    .font(Typo.code)
            } else {
                Label("Preview", systemImage: "doc.richtext")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .foregroundStyle(isPresented ? Palette.accent : Palette.textSecondary)
        .help(isPresented ? "Go back to code" : "Show Markdown preview")
        .accessibilityLabel(isPresented ? "Go back to code" : "Show Markdown preview")
    }
}
