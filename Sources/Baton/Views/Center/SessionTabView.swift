import SwiftUI
import BatonCore

/// One conversation in the tab strip.
///
/// The tab owns its own hover and its own rename field. The strip only says which tab is being
/// renamed, so two tabs can never both think they hold the editor.
struct SessionTabView: View {
    var session: Session
    var isActive: Bool
    var isRunning: Bool
    var isRenaming: Bool
    var canClose: Bool
    var onSelect: @MainActor () -> Void
    var onStartRename: @MainActor () -> Void
    var onCommitRename: @MainActor (String) -> Void
    var onCancelRename: @MainActor () -> Void
    var onClose: @MainActor () -> Void

    /// A tab stops growing here so one long title cannot push every other tab out of the strip.
    private static let maximumWidth: CGFloat = 200
    /// Wide enough for the titles sessions actually get, and the same width whichever tab is
    /// being renamed, so the strip does not jump as the editor opens.
    private static let renameWidth: CGFloat = 140

    @State private var isHovered = false
    @State private var renameText = ""
    @FocusState private var isRenameFocused: Bool

    private var title: String {
        session.title.isEmpty ? "Untitled" : session.title
    }

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            if isRunning {
                ActivityDot(isActive: true)
                    .accessibilityLabel("Running")
            }

            if isRenaming {
                TextField("Session name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(Typo.label)
                    .focused($isRenameFocused)
                    .frame(width: Self.renameWidth)
                    .onSubmit { onCommitRename(renameText) }
                    .onExitCommand(perform: onCancelRename)
            } else {
                Text(title)
                    .font(isActive ? Typo.labelEmphasis : Typo.label)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
            }

            closeButton
        }
        .padding(.horizontal, Metrics.inset)
        .frame(maxWidth: Self.maximumWidth)
        .frame(height: Metrics.barHeight)
        // The selected tab takes the content colour and fills the strip's full height, the way an
        // editor tab bar on this platform does. A rounded capsule of selection grey floating in a
        // strip is a browser chrome idiom, and it read as a solid block rather than as a tab.
        .background(background)
        .contentShape(Rectangle())
        // A single click selects and a double click renames, which is one gesture with two
        // meanings rather than a button, so it cannot be expressed as one.
        .gesture(
            TapGesture(count: 2)
                .onEnded { onStartRename() }
                .exclusively(before: TapGesture().onEnded { onSelect() })
        )
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", onSelect)
        .accessibilityAction(named: "Rename", onStartRename)
        .contextMenu {
            Button("Rename", action: onStartRename)
            Button("Close", action: onClose)
                .disabled(!canClose)
        }
        .task(id: isRenaming) { await startEditing() }
    }

    private var background: Color {
        if isActive { return Palette.surface }
        return isHovered ? Palette.hover : .clear
    }

    /// Kept in the layout even when it is invisible, so no label moves when the pointer enters.
    /// Shown on the selected tab as well as the hovered one, because the tab you are looking at is
    /// the one you are most likely to want to close.
    private var closeButton: some View {
        Button(action: onClose) {
            Label("Close session", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: Metrics.glyph, height: Metrics.glyph)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!canClose)
        .help("Close session")
    }

    private var isVisible: Bool {
        canClose && (isHovered || isActive)
    }

    /// The field only exists from the moment the strip says so, and a brand new field cannot take
    /// focus in the same pass it is created in.
    private func startEditing() async {
        guard isRenaming else { return }
        renameText = session.title
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }
        isRenameFocused = true
    }
}
