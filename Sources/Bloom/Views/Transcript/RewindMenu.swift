import SwiftUI

/// The Rewind menu beside an owner's message, next to "Copy this prompt". Two items rather
/// than a button and a confirmation, because which of the two is meant is the question a
/// confirmation would have asked anyway, and choosing one is the deliberate second step.
///
/// Drawn the way `CopyButton` is: there on hover, clear otherwise rather than faded out, so it
/// stays in the accessibility tree and reachable by Tab.
struct RewindMenu: View {
    var seq: Int
    var rewind: @MainActor @Sendable (Int, Bool) -> Void
    var isVisible: Bool

    var body: some View {
        Menu {
            Button("Rewind Conversation to Before This Message") { rewind(seq, false) }
            Button("Rewind Conversation and Files to Before This Message") { rewind(seq, true) }
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(Typo.caption)
                .imageScale(.small)
                .frame(width: 16, height: 16)
                .foregroundStyle(isVisible ? Palette.textTertiary : Color.clear)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rewind to before this message")
        .accessibilityLabel("Rewind to before this message")
    }
}
