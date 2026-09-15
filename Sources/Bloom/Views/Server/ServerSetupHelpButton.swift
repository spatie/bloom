import SwiftUI
import AppKit

/// Hover gives a quick explanation; clicking keeps recovery instructions selectable and copyable.
struct ServerSetupHelpButton: View {
    let title: String
    let details: String
    @State private var isPresented = false

    var body: some View {
        Button(title, systemImage: "questionmark.circle") { isPresented.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(minWidth: 24, minHeight: 24)
            .help(details)
            .popover(isPresented: $isPresented) {
                VStack(alignment: .leading, spacing: Metrics.gutter) {
                    Text(title).font(Typo.labelEmphasis)
                    ScrollView {
                        Text(details).font(Typo.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 260)
                    Button("Copy Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details, forType: .string)
                    }
                }
                .padding(Metrics.gutter)
                .frame(width: 380)
            }
    }
}
