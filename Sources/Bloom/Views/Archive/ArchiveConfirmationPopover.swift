import SwiftUI
import BloomCore

struct ArchiveConfirmationPopover: View {
    let request: ArchiveRequest
    var canConfirm = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ConfirmationPopover(
            title: "Archive this workspace?",
            confirmLabel: request.confirmLabel,
            tint: tint,
            canConfirm: canConfirm,
            onConfirm: onConfirm,
            onCancel: onCancel,
            width: 380
        ) {
            ViewThatFits(in: .vertical) {
                Text(request.message).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(request.message).frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: 440)
        }
    }

    private var tint: Color {
        if request.isDestructive { return Palette.negative }
        return request.hazards.isPullRequestMerged ? Palette.mergedFill : Palette.controlAccent
    }
}

extension View {
    /// Attach this to the initiating control, which stays in the hierarchy until dismissal.
    func archiveConfirmation(
        _ request: Binding<ArchiveRequest?>,
        arrowEdge: Edge = .top,
        canConfirm: Bool = true,
        onConfirm: @escaping (ArchiveRequest) -> Void
    ) -> some View {
        popover(item: request, arrowEdge: arrowEdge) { value in
            ArchiveConfirmationPopover(
                request: value,
                canConfirm: canConfirm,
                onConfirm: {
                    request.wrappedValue = nil
                    onConfirm(value)
                },
                onCancel: { request.wrappedValue = nil }
            )
        }
    }
}
