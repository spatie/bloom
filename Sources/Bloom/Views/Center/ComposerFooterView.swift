import SwiftUI
import BloomCore

/// Everything the user can change about the next turn: the model, the effort, the permission mode,
/// whether it runs fast, what it has attached, and whether it goes now.
///
/// It is written against `ComposerControls` rather than against a `Session`, because the create
/// sheet uses this same row before any session exists. Both callers hand over the four choices and
/// take back the changed set; where they keep them is their own business.
struct ComposerFooterView: View {
    var controls: ComposerControls
    var onChange: @MainActor (ComposerControls) -> Void
    /// Nil until the session has run a turn, because that is the first moment the agent says
    /// anything about the window. Absent rather than zero: a gauge reading 0% would be a claim.
    /// Always nil in the create sheet, where there is not yet anything to report.
    var context: ContextWindowUsage?
    var isRunning: Bool = false
    var canSend: Bool
    /// What the button at the end of the row does. See `ComposerIntent`.
    var intent: ComposerIntent = .send
    var onAttach: @MainActor () -> Void
    var onSend: @MainActor () -> Void
    var onStop: @MainActor () -> Void = {}
    /// Model and effort ids this footer has been set to that are not on the built-in lists, kept
    /// so the menu can offer the way back. See `ComposerOption.adding`.
    ///
    /// Held here rather than in `ComposerOptionMenu` because `ViewThatFits` below builds the row
    /// three times, and three copies of the menu would be three separate pieces of state.
    @State private var extraModels: [String] = []
    @State private var extraEfforts: [String] = []

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
        .onChange(of: controls.model, initial: true) { _, id in
            remember(id, known: ComposerOption.models, in: &extraModels)
        }
        .onChange(of: controls.effort, initial: true) { _, id in
            remember(id, known: ComposerOption.efforts, in: &extraEfforts)
        }
    }

    /// Files an id the built-in list has no entry for, once.
    private func remember(_ id: String, known: [ComposerOption], in list: inout [String]) {
        guard !id.isEmpty, !known.contains(where: { $0.id == id }), !list.contains(id) else { return }
        list.append(id)
    }

    private func row(isCompact: Bool, showsContext: Bool) -> some View {
        HStack(spacing: Metrics.spacingTight) {
            ComposerOptionMenu(
                options: ComposerOption.adding(extraModels, to: ComposerOption.models),
                selection: controls.model,
                title: "Model",
                systemImage: "sparkle",
                isCompact: isCompact,
                help: "Choose the model",
                onSelect: { id in edit { $0.model = id } }
            )

            ComposerOptionMenu(
                options: ComposerOption.adding(extraEfforts, to: ComposerOption.efforts),
                selection: controls.effort,
                title: "Reasoning effort",
                systemImage: "chart.bar.fill",
                isCompact: isCompact,
                help: "Choose reasoning effort",
                onSelect: { id in edit { $0.effort = id } }
            )

            ComposerOptionMenu(
                options: ComposerOption.permissionModes,
                selection: controls.permissionMode.rawValue,
                title: "Permission mode",
                systemImage: Self.permissionGlyph(controls.permissionMode),
                tint: controls.permissionMode == .bypassPermissions
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
                intent: intent,
                isRunning: isRunning,
                canSend: canSend,
                onSend: onSend,
                onStop: onStop
            )
        }
    }

    private func fastToggle(isCompact: Bool) -> some View {
        Button {
            edit { $0.isFastMode.toggle() }
        } label: {
            ComposerControlLabel(
                systemImage: "bolt.fill",
                text: isCompact ? nil : "Fast",
                tint: controls.isFastMode ? Palette.accent : Palette.textSecondary,
                isActive: controls.isFastMode
            )
        }
        .buttonStyle(.plain)
        .help("Fast mode trades some reasoning for a quicker reply")
        .accessibilityLabel("Fast mode")
        .accessibilityAddTraits(controls.isFastMode ? .isSelected : [])
    }

    // MARK: - Edits

    private func edit(_ change: (inout ComposerControls) -> Void) {
        var changed = controls
        change(&changed)
        guard changed != controls else { return }
        onChange(changed)
    }

    private func selectPermissionMode(_ id: String) {
        guard let mode = PermissionMode(rawValue: id) else { return }
        edit { $0.permissionMode = mode }
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
