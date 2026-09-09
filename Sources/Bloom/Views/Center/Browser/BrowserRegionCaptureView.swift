import SwiftUI
import BloomCore

/// The selection is an overlay on the viewport, never a replacement layout. The same editor a
/// diff line opens lives in a popover, so neither selecting nor typing changes the page's size.
struct BrowserRegionCaptureView: View {
    @Bindable var capture: BrowserRegionCapture
    var cancel: @MainActor () -> Void
    var add: @MainActor () -> Void

    var body: some View {
        GeometryReader { proxy in
            let page = BrowserRegion.rect(capture.pageRect, in: CGRect(origin: .zero, size: proxy.size))
            let anchor = capture.selection.map { BrowserRegion.rect($0, in: page) } ?? page
            BrowserRegionCanvas(capture: capture) { capture.isEditing = true }
                .popover(isPresented: $capture.isEditing, attachmentAnchor: .rect(.rect(anchor))) {
                    editor
                }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ReviewCommentEditorView(
                text: $capture.comment,
                width: 380,
                onCommit: { if capture.canAdd { add() } },
                onCancel: cancel
            )
            .disabled(capture.isAdding)
            if let failure = capture.failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Metrics.inset)
            }
        }
        .frame(width: 380)
        .background(Palette.reviewBand)
    }
}
