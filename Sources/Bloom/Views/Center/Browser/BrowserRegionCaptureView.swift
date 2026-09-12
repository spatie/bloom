import SwiftUI
import BloomCore

/// These bands are ordinary overlays, not popovers. Only the band itself takes clicks, so the
/// same mouse-down that starts a new selection reaches the page while a comment is open.
struct BrowserRegionCaptureView<Model: WorkspacePaneModel>: View {
    @Bindable var capture: BrowserRegionCapture
    var model: Model
    var viewportFrame: CGRect
    var add: @MainActor () -> Void
    @State private var panelSize = CGSize(width: 380, height: 100)

    var body: some View {
        GeometryReader { proxy in
            let page = BrowserRegion.rect(capture.pageRect, in: viewportFrame)
            let selection = capture.selection ?? capture.focusedComment?.selection
            if let selection, capture.isEditing || capture.focusedComment != nil {
                let anchor = BrowserRegion.rect(selection, in: page)
                let size = CGSize(width: min(380, max(0, proxy.size.width - 16)), height: panelSize.height)
                let frame = BrowserRegion.commentFrame(near: anchor, in: CGRect(origin: .zero, size: proxy.size), size: size)
                ScrollView {
                    panel(width: frame.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
                }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: frame.width, height: frame.height)
                    .background(Palette.reviewBand, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                    .overlay { RoundedRectangle(cornerRadius: Metrics.cornerSmall).strokeBorder(Palette.border, lineWidth: Metrics.outline) }
                    .elevation(.resting)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .onChange(of: model.existingTranscript(for: capture.sessionID)?.draft) {
            guard let transcript = model.existingTranscript(for: capture.sessionID) else { return }
            capture.synchronise(with: transcript.draft)
        }
    }

    @ViewBuilder private func panel(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            if capture.isEditing {
                if capture.editingCommentPath != nil {
                    VStack(spacing: Metrics.spacing) {
                        ReviewCommentField(text: $capture.comment, placeholder: "Leave a comment", onSubmit: save, onCancel: capture.cancelEdit)
                        ReviewCommentEditorButtons(
                            confirmTitle: "Save", canConfirm: ReviewCommentEdit.canSubmit(capture.comment),
                            confirmHelp: "Save the comment (Return)", onConfirm: save, onCancel: capture.cancelEdit
                        )
                    }
                    .padding(.horizontal, Metrics.inset)
                    .padding(.vertical, Metrics.spacingWide)
                    .frame(width: width)
                } else {
                    ReviewCommentEditorView(
                        text: $capture.comment, width: width,
                        onCommit: { if capture.canAdd { add() } }, onCancel: capture.cancelEdit
                    )
                }
            } else if let note = capture.focusedComment {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
                    Image(systemName: "text.bubble").font(Typo.micro).foregroundStyle(Palette.textSecondary)
                    Text(note.body)
                        .font(Typo.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(note.body)
                    Button("Edit comment", systemImage: "pencil") { capture.beginEdit(note) }
                        .labelStyle(.iconOnly)
                    Button("Remove comment", systemImage: "xmark") { capture.remove(note, from: model) }
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .font(Typo.micro)
                .padding(.horizontal, Metrics.inset)
                .padding(.vertical, Metrics.spacingWide)
                .frame(width: width)
            }
            if let failure = capture.failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Metrics.inset)
            }
        }
        .disabled(capture.isAdding)
    }

    private func save() {
        guard !capture.isAdding else { return }
        capture.saveEdit(in: model)
    }
}
