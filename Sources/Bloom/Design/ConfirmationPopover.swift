import SwiftUI

/// Shared native popover content for confirmations attached to their initiating controls.
struct ConfirmationPopover<Content: View>: View {
    let title: String
    let confirmLabel: String
    let tint: Color
    var canConfirm = true
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var width: CGFloat = 340
    @ViewBuilder var content: () -> Content

    @FocusState private var focus: Field?

    private enum Field: Hashable { case cancel, confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content()

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .focused($focus, equals: .cancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) {
                    guard canConfirm else { return }
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .focused($focus, equals: .confirm)
                .disabled(!canConfirm)
            }
            .padding(.top, 4)
        }
        // A selected sidebar row inverts its ink. The popover has its own neutral surface.
        .environment(\.backgroundProminence, .standard)
        .foregroundStyle(.primary)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: width)
        // Colour is independent of the default action: Return must never confirm.
        .defaultFocus($focus, .cancel)
    }
}
