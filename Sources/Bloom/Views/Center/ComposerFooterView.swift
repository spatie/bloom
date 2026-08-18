import SwiftUI
import BloomCore

/// Everything the user can change about the next turn: the model, the effort, the permission mode,
/// whether it runs fast, what it has attached, and whether it goes now.
struct ComposerFooterView: View {
    var session: Session
    var editor: ComposerSessionEditor
    /// Nil until the session has run a turn, because that is the first moment the agent says
    /// anything about the window. Absent rather than zero: a gauge reading 0% would be a claim.
    var context: ContextWindowUsage?
    var isRunning: Bool
    var isFastMode: Bool
    var canSend: Bool
    var onToggleFastMode: @MainActor () -> Void
    var onAttach: @MainActor () -> Void
    var onSend: @MainActor () -> Void
    var onStop: @MainActor () -> Void

    var body: some View {
        // The footer is a fixed row of controls in a pane whose width the user owns: the centre
        // column can be dragged to 420 points and then split in two, and at that width the full
        // row does not fit. Left to overflow it clipped from both edges at once, which took the
        // model picker off one end and the attach and send buttons off the other, so the composer
        // had no way to send. Each step drops the least load-bearing thing left: first the words
        // beside the three picker glyphs, then the context reading, which is the one control here
        // that reports rather than does.
        ViewThatFits(in: .horizontal) {
            row(isCompact: false, showsContext: true)
            row(isCompact: true, showsContext: true)
            row(isCompact: true, showsContext: false)
        }
    }

    private func row(isCompact: Bool, showsContext: Bool) -> some View {
        HStack(spacing: Metrics.spacingTight) {
            ComposerOptionMenu(
                options: ComposerOption.models,
                selection: session.model,
                systemImage: "sparkle",
                isCompact: isCompact,
                help: "Choose the model",
                onSelect: selectModel
            )

            ComposerOptionMenu(
                options: ComposerOption.efforts,
                selection: session.effort,
                systemImage: "chart.bar.fill",
                isCompact: isCompact,
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
                isCompact: isCompact,
                help: "Choose permission mode",
                onSelect: selectPermissionMode
            )

            // After the three pickers rather than between them: the pickers all answer "which",
            // and a toggle wedged into that run made the row read as four unrelated controls.
            fastToggle(isCompact: isCompact)

            Spacer(minLength: Metrics.spacing)

            // On the far side of the spacer, away from the pickers. It is a reading rather than
            // something to choose, and among the three menus it read as a fourth one.
            if let context, showsContext {
                ComposerContextGauge(usage: context)
            }

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
    private func fastToggle(isCompact: Bool) -> some View {
        Button(action: onToggleFastMode) {
            ComposerControlLabel(
                systemImage: "bolt.fill",
                text: isCompact ? nil : "Fast",
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
