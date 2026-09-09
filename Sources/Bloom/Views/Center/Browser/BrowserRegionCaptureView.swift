import SwiftUI
import BloomCore

/// The page and the feedback have separate surfaces: the crop stays readable while the comment
/// grows, and the destination is visible before anything is added to a conversation.
struct BrowserRegionCaptureView: View {
    @Bindable var capture: BrowserRegionCapture
    var cancel: @MainActor () -> Void
    var add: @MainActor () -> Void
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            BrowserRegionCanvas(capture: capture) { commentFocused = true }
            Hairline()
            composer
        }
        .background(Palette.surface)
    }

    private var header: some View {
        HStack(spacing: Metrics.gutter) {
            Image(systemName: "crop")
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30)
                .background(Palette.questionWash, in: RoundedRectangle(cornerRadius: Metrics.corner))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Comment on an area")
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Text("Snapshot · \(source)")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(capture.address)
            }
            Spacer(minLength: 0)
            Button("Cancel", systemImage: "xmark", action: cancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.accessoryBar)
                .keyboardShortcut(.cancelAction)
                .help("Cancel capture (Esc)")
                .disabled(capture.isAdding)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: capture.selection == nil ? "cursorarrow" : "checkmark.circle.fill")
                    .foregroundStyle(capture.selection == nil ? Palette.textSecondary : Palette.accent)
                    .accessibilityHidden(true)
                Text(capture.selection == nil
                    ? "Drag over the area you want to discuss."
                    : "Drag inside to move. Use the corners to resize.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("What should change?", text: $capture.comment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .lineLimit(2...5)
                .focused($commentFocused)
                .accessibilityLabel("Comment about the selected area")
                .padding(12)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(
                        commentFocused ? Palette.focusRing : Palette.border,
                        lineWidth: commentFocused ? 1.5 : Metrics.outline
                    )
                }
            if let failure = capture.failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 8) {
                Label(capture.conversation, systemImage: "text.bubble")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .help("Adds to the draft in \(capture.conversation). Nothing is sent yet.")
                Spacer(minLength: 0)
                Text("Draft only")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
            }
            HStack {
                Menu {
                    Button("Select All") {
                        capture.selection = CGRect(x: 0, y: 0, width: 1, height: 1)
                        commentFocused = true
                    }
                    Button("Clear Selection") { capture.selection = nil }
                        .disabled(capture.selection == nil)
                } label: {
                    Label("Selection", systemImage: "rectangle.dashed")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(Typo.label)
                .help("Select the whole screenshot or start a new selection")
                Spacer(minLength: Metrics.spacingSmall)
                Button(action: add) {
                    HStack(spacing: 8) {
                        if capture.isAdding { ProgressView().controlSize(.mini) }
                        Text(capture.isAdding ? "Adding…" : "Add to Draft")
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentFill)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Add screenshot and comment to the draft (⌘Return)")
                .disabled(!capture.canAdd)
            }
            .controlSize(.regular)
        }
        .padding(16)
        .background(Palette.surfaceSunken)
        .disabled(capture.isAdding)
    }

    private var source: String {
        let display = BrowserAddressDisplay.of(capture.address)
        let label = display.host + display.trailing
        return label.isEmpty ? capture.address : label
    }
}
