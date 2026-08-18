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

    @State private var isHovered = false
    @State private var renameText = ""
    @FocusState private var isRenameFocused: Bool

    private var title: String {
        session.title.isEmpty ? "Untitled" : session.title
    }

    var body: some View {
        HStack(spacing: Metrics.cornerSmall) {
            if isRunning {
                ActivityDot(isActive: true)
                    .accessibilityLabel("Running")
            }

            if isRenaming {
                TextField("Session name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(Typo.label)
                    .focused($isRenameFocused)
                    .frame(width: Metrics.sidebarWidth / 2)
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
        .padding(.horizontal, Metrics.corner)
        .frame(height: Metrics.rowHeight)
        .background(
            isActive ? Palette.selected : (isHovered ? Palette.hover : .clear),
            in: .capsule
        )
        .contentShape(Rectangle())
        // A single click selects and a double click renames, which is one gesture with two
        // meanings rather than a button, so it cannot be expressed as one.
        .gesture(
            TapGesture(count: 2)
                .onEnded { onStartRename() }
                .exclusively(before: TapGesture().onEnded { onSelect() })
        )
        .onHover { isHovered = $0 }
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

    /// Kept in the layout even when it is invisible, so no label moves when the pointer enters.
    private var closeButton: some View {
        Button(action: onClose) {
            Label("Close session", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: Metrics.rowHeight / 2, height: Metrics.rowHeight / 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(isHovered && canClose ? 1 : 0)
        .allowsHitTesting(isHovered && canClose)
        .accessibilityHidden(!canClose)
        .help("Close session")
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
