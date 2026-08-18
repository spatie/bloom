import SwiftUI
import BloomCore

/// Everything the user can change about the next turn: the model, the effort, the permission mode,
/// whether it runs fast, what it has attached, and whether it goes now.
struct ComposerFooterView: View {
    var session: Session
    var editor: ComposerSessionEditor
    var isRunning: Bool
    var isFastMode: Bool
    var canSend: Bool
    var onToggleFastMode: @MainActor () -> Void
    var onAttach: @MainActor () -> Void
    var onSend: @MainActor () -> Void
    var onStop: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacingTight) {
            ComposerOptionMenu(
                options: ComposerOption.models,
                selection: session.model,
                systemImage: "sparkle",
                help: "Choose the model",
                onSelect: selectModel
            )

            ComposerOptionMenu(
                options: ComposerOption.efforts,
                selection: session.effort,
                systemImage: "chart.bar.fill",
                help: "Choose reasoning effort",
                onSelect: selectEffort
            )

            ComposerOptionMenu(
                options: ComposerOption.permissionModes,
                selection: session.permissionMode.rawValue,
                systemImage: Self.permissionGlyph(session.permissionMode),
                tint: session.permissionMode == .bypassPermissions
                    ? Palette.warning
                    : Palette.textSecondary,
                help: "Choose permission mode",
                onSelect: selectPermissionMode
            )

            // After the three pickers rather than between them: the pickers all answer "which",
            // and a toggle wedged into that run made the row read as four unrelated controls.
            fastToggle

            Spacer(minLength: Metrics.spacing)

            // A paperclip, not the plus that used to sit here: a plus already means "new session"
            // in the tab strip directly above, and it says nothing about what is being added.
            Button(action: onAttach) {
                ComposerControlLabel(systemImage: "paperclip", text: nil)
            }
            .buttonStyle(.plain)
            .help("Attach a file")
            .accessibilityLabel("Attach a file")

            ComposerSendButton(
                isRunning: isRunning,
                canSend: canSend,
                onSend: onSend,
                onStop: onStop
            )
        }
    }

    /// Fast mode has no column on `Session`, so the composer keeps it in the store's key value
    /// table. It is still per session and it still survives a relaunch, which is all it promises.
    private var fastToggle: some View {
        Button(action: onToggleFastMode) {
            ComposerControlLabel(
                systemImage: "bolt.fill",
                text: "Fast",
                tint: isFastMode ? Palette.accent : Palette.textSecondary,
                isActive: isFastMode
            )
        }
        .buttonStyle(.plain)
        .help("Fast mode trades some reasoning for a quicker reply")
        .accessibilityLabel("Fast mode")
        .accessibilityAddTraits(isFastMode ? .isSelected : [])
    }

    // MARK: - Edits

    private func selectModel(_ id: String) {
        editor.apply { $0.model = id }
    }

    private func selectEffort(_ id: String) {
        editor.apply { $0.effort = id }
    }

    private func selectPermissionMode(_ id: String) {
        guard let mode = PermissionMode(rawValue: id) else { return }
        editor.apply { $0.permissionMode = mode }
    }

    private static func permissionGlyph(_ mode: PermissionMode) -> String {
        switch mode {
        case .auto: "hand.raised"
        case .acceptEdits: "checkmark.shield"
        case .bypassPermissions: "exclamationmark.shield"
        case .plan: "list.bullet.rectangle"
        }
    }
}
