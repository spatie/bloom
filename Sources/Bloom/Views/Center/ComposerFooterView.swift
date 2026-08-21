import SwiftUI
import BloomCore

/// Everything the user can change about the next turn: the model, the effort, the output style,
/// the permission mode, whether it runs fast, what it has attached, and whether it goes now.
///
/// It is written against `ComposerControls` rather than against a `Session`, because the create
/// sheet uses this same row before any session exists. Both callers hand over the choices and take
/// back the changed set; where they keep them is their own business.
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
    /// The checkout the output style menu should look in for styles this project defines, or nil
    /// where there is not one yet. A repository can carry its own `.claude/output-styles`, and in
    /// the create sheet the worktree does not exist, so the repository is the honest answer there.
    var project: String?
    var onAttach: @MainActor () -> Void
    var onSend: @MainActor () -> Void
    var onStop: @MainActor () -> Void = {}
    /// Whether the row carries the choices the agent runs on.
    ///
    /// False for a terminal workspace, which has no agent: the create sheet was offering a model,
    /// a reasoning effort, a permission mode, fast mode and a paperclip for a workspace that opens
    /// a shell and never sends any of them anywhere. What is left is the send button, which is the
    /// one control on the row that still does something.
    var showsAgentControls: Bool = true

    /// Model and effort ids this footer has been set to that are not on the built-in lists, kept
    /// so the menu can offer the way back. See `ComposerOption.adding`.
    ///
    /// Held here rather than in `ComposerOptionMenu` because `ViewThatFits` below builds the row
    /// three times, and three copies of the menu would be three separate pieces of state.
    @State private var extraModels: [String] = []
    @State private var extraEfforts: [String] = []

    /// The output styles this checkout offers. Held here rather than shared, unlike the model
    /// catalogue below, because its answer depends on which repository the footer is pointing at
    /// and one composer only ever points at one. `ViewThatFits` still gets a single copy, because
    /// the three rows it builds are three renders of this one view.
    @State private var outputStyles = ComposerOutputStyleCatalog()

    /// Shared, because `ViewThatFits` below builds this row three times and three copies would be
    /// three fetches of the Codex model list.
    private var catalog: ComposerModelCatalog { ComposerModelCatalog.shared }

    var body: some View {
        // The footer is a fixed row of controls in a pane whose width the user owns: the centre
        // column can be dragged to 420 points and then split in two, and at that width the full
        // row does not fit. Left to overflow it clipped from both edges at once, which took the
        // model picker off one end and the attach and send buttons off the other, so the composer
        // had no way to send. Each step drops the least load-bearing thing left: first the words
        // beside the picker glyphs, then the context reading, which is the one control here that
        // reports rather than does.
        ViewThatFits(in: .horizontal) {
            row(isCompact: false, showsContext: true)
            row(isCompact: true, showsContext: true)
            row(isCompact: true, showsContext: false)
        }
        .onChange(of: controls.model, initial: true) { _, id in
            remember(id, known: catalog.options(for: controls.agentKind), in: &extraModels)
        }
        .onChange(of: controls.effort, initial: true) { _, id in
            remember(id, known: efforts, in: &extraEfforts)
        }
        // On appearance rather than on first use of the menu, so the Codex section is there when
        // the menu is opened rather than a moment after. It fetches once.
        .task { if showsAgentControls { catalog.load() } }
        // Re-run when the composer moves to another checkout, because a project's own styles are
        // that project's. The scan itself does nothing when the answer is already held and fresh.
        .task(id: project) {
            if showsAgentControls { await outputStyles.refreshIfStale(project: project) }
        }
    }

    /// Files an id the built-in list has no entry for, once.
    private func remember(_ id: String, known: [ComposerOption], in list: inout [String]) {
        guard !id.isEmpty, !known.contains(where: { $0.id == id }), !list.contains(id) else { return }
        list.append(id)
    }

    private func row(isCompact: Bool, showsContext: Bool) -> some View {
        HStack(spacing: Metrics.spacingTight) {
            if showsAgentControls {
                ComposerOptionMenu(
                    options: [],
                    // One section per backend that can run a chat. A flat list of five names says
                    // nothing about which agent each one belongs to, and picking a name here is
                    // picking an agent.
                    sections: catalog.sections(includingCurrent: controls.model, on: controls.agentKind),
                    selection: controls.model,
                    // No heading. Opus 5 and Sonnet 5 are names, and the chip this opened from is
                    // showing one of them.
                    heading: nil,
                    systemImage: "sparkle",
                    isCompact: isCompact,
                    help: "Choose the model",
                    onSelect: selectModel
                )

                ComposerOptionMenu(
                    options: ComposerOption.adding(extraEfforts, to: efforts),
                    selection: controls.effort,
                    heading: "Reasoning effort",
                    systemImage: "chart.bar.fill",
                    isCompact: isCompact,
                    help: "Choose reasoning effort",
                    onSelect: { id in edit { $0.effort = id } }
                )

                // Beside the model and the effort rather than after the permission mode, because
                // those three all answer "how does it think and how does it write", and the
                // permission mode answers "what may it touch". Absent entirely for Codex, which
                // has no output styles: see `ComposerControls.offersOutputStyle`.
                if controls.offersOutputStyle {
                    ComposerOptionMenu(
                        options: outputStyles.options(includingCurrent: controls.outputStyle),
                        // The selected style, in its own words. The CLI's own sentence for the
                        // four it compiles in, and the file's `description` for a custom one.
                        footnote: outputStyles.detail(of: controls.outputStyle),
                        selection: controls.outputStyle,
                        heading: "Output style",
                        systemImage: "textformat",
                        isCompact: isCompact,
                        help: "Choose the output style",
                        onSelect: { id in edit { $0.outputStyle = id } }
                    )
                }

                ComposerOptionMenu(
                    options: controls.availablePermissionModes.map {
                        ComposerOption(id: $0.rawValue, label: $0.label)
                    },
                    footnote: controls.missingPermissionModeNote,
                    selection: controls.permissionMode.rawValue,
                    heading: "Permission mode",
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
            }

            Spacer(minLength: Metrics.spacing)

            // On the far side of the spacer, away from the pickers. It is a reading rather than
            // something to choose, and among the three menus it read as a fourth one.
            if let context, showsContext {
                ComposerContextGauge(usage: context)
            }

            // A paperclip, not the plus that used to sit here: a plus already means "new session"
            // in the tab strip directly above, and it says nothing about what is being added.
            // Gone with the rest when there is no agent: nothing reads an attachment into a shell.
            if showsAgentControls {
                Button(action: onAttach) {
                    ComposerControlLabel(systemImage: "paperclip", text: nil)
                }
                .buttonStyle(.plain)
                .help("Attach a file")
                .accessibilityLabel("Attach a file")
            }

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

    /// The efforts the chosen model actually takes.
    ///
    /// Claude Code's five are the same for every model. Codex's differ per model, measured against
    /// the real `model/list`: `gpt-5.6-sol` takes six levels up to `ultra`, `gpt-5.5` stops at
    /// `xhigh`. Offering a level the model does not take is offering something the server refuses.
    private var efforts: [ComposerOption] {
        catalog.efforts(for: controls.agentKind, model: controls.model)
    }

    /// Choosing a model out of another backend's section is choosing that backend.
    ///
    /// Three things move together, which is why this is not three separate edits: the model, the
    /// backend it belongs to, and the effort, which has to land on something the new model takes.
    /// The caller decides what changing the backend means, because a chat that has already spoken
    /// forks rather than changing. See `BackendChange`.
    private func selectModel(_ id: String) {
        let backend = catalog.backend(ofModel: id, current: controls.agentKind)
        edit {
            $0.model = id
            $0.agentKind = backend
            $0.effort = catalog.resolvedEffort($0.effort, for: backend, model: id)
            // A mode the new backend does not have cannot survive the move. Codex has no Plan, and
            // a chat left holding it would be in a mode nothing implements.
            if !$0.availablePermissionModes.contains($0.permissionMode) {
                $0.permissionMode = .acceptEdits
            }
        }
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
