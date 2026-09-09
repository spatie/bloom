import SwiftUI
import BloomCore

/// Size controls live behind the toolbar button so previewing a narrow page does not cost a
/// permanent second toolbar. Closing the popover keeps the viewport; Full size leaves preview.
struct BrowserViewportButton: View {
    @Binding var viewport: BrowserViewport
    @State private var showsControls = false

    var body: some View {
        Button {
            showsControls.toggle()
        } label: {
            Label("Responsive Preview", systemImage: "ipad.and.iphone")
                .labelStyle(.iconOnly)
                .foregroundStyle(viewport.isEnabled ? Palette.accent : Palette.textSecondary)
        }
        .buttonStyle(.accessoryBar)
        .help(viewport.isEnabled
            ? "Viewport: \(viewport.width) × \(viewport.height). Show size controls or restore full size"
            : "Preview at phone, tablet and desktop sizes")
        .accessibilityValue(viewport.isEnabled ? "\(viewport.width) × \(viewport.height)" : "Full size")
        .popover(isPresented: $showsControls, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Responsive preview").font(Typo.labelEmphasis)
                BrowserViewportBar(viewport: $viewport)
                Divider()
                Button("Full size", systemImage: "arrow.up.left.and.arrow.down.right") {
                    viewport.isEnabled = false
                    showsControls = false
                }
                .buttonStyle(.borderless)
                .disabled(!viewport.isEnabled)
                .help("Restore the page to the full browser pane")
            }
            .controlSize(.small)
            .padding(20)
            .frame(width: 430)
        }
    }
}
