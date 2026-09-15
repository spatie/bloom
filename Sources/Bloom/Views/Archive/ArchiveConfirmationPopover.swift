import SwiftUI
import BloomCore

struct ArchiveConfirmationPopover: View {
    let request: ArchiveRequest
    var canConfirm = true
    var tint: Color = Palette.controlAccent
    /// Handed the request as the owner left it, Docker choice included.
    let onConfirm: (ArchiveRequest) -> Void
    let onCancel: () -> Void

    @State private var removesDocker: Bool

    init(request: ArchiveRequest, canConfirm: Bool = true, tint: Color = Palette.controlAccent,
         onConfirm: @escaping (ArchiveRequest) -> Void, onCancel: @escaping () -> Void) {
        self.request = request; self.canConfirm = canConfirm; self.tint = tint
        self.onConfirm = onConfirm; self.onCancel = onCancel
        _removesDocker = State(initialValue: request.removesDocker)
    }

    private var answered: ArchiveRequest {
        var value = request
        value.removesDocker = removesDocker
        return value
    }

    var body: some View {
        ConfirmationPopover(
            title: "Archive this workspace?",
            confirmLabel: answered.confirmLabel,
            tint: tint,
            canConfirm: canConfirm,
            onConfirm: { onConfirm(answered) },
            onCancel: onCancel,
            width: 380
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .vertical) {
                    Text(answered.message).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(answered.message).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: 440)
                if request.offersDockerRemoval {
                    Toggle(request.dockerToggleLabel, isOn: $removesDocker)
                        .toggleStyle(.checkbox)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

}

extension View {
    /// Attach this to the initiating control, which stays in the hierarchy until dismissal.
    ///
    /// `tint` is the initiating control's own colour where it has one, so the confirm button
    /// matches the button that opened it. The pull request strip's Archive is the merged band's
    /// purple; a sidebar row has no coloured control and keeps the accent.
    func archiveConfirmation(
        _ request: Binding<ArchiveRequest?>,
        arrowEdge: Edge = .top,
        canConfirm: Bool = true,
        tint: Color = Palette.controlAccent,
        onConfirm: @escaping (ArchiveRequest) -> Void
    ) -> some View {
        popover(item: request, arrowEdge: arrowEdge) { value in
            ArchiveConfirmationPopover(
                request: value,
                canConfirm: canConfirm,
                tint: tint,
                onConfirm: { answered in
                    request.wrappedValue = nil
                    onConfirm(answered)
                },
                onCancel: { request.wrappedValue = nil }
            )
        }
    }
}
