import SwiftUI
import BloomCore

/// One calm entry point for the settings that qualify the next agent turn.
///
/// Model, effort, output style and permissions used to compete as adjacent controls. They belong
/// to one decision, so the footer keeps that decision visible and offers it two ways: a menu of the
/// owner's saved presets, which sets every field at once, and "Custom…", the full panel for a
/// one-off. The panel can save what it is set to as a new preset.
///
/// Fast mode is not in here any more. It is `ComposerFastModeToggle`, beside this button, because
/// it combines with any preset rather than being one of the things a preset chooses.
struct ComposerSettingsPicker: View {
    var controls: ComposerControls
    var models: [ComposerModelSection]
    var efforts: [ComposerOption]
    var outputStyles: [ComposerOption]
    var permissionModes: [ComposerOption]
    var isCompact: Bool
    var onPreset: @MainActor (ModelPreset) -> Void
    var onModel: @MainActor (String) -> Void
    var onEffort: @MainActor (String) -> Void
    var onOutputStyle: @MainActor (String) -> Void
    var onPermissionMode: @MainActor (String) -> Void
    var onContextWindow: @MainActor (Int) -> Void
    var onInteractionMode: @MainActor (InteractionMode) -> Void = { _ in }
    var onAdvisor: @MainActor (ChatAdvisor) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var isOpen = false

    private var library: ModelPresetLibrary { .shared }

    var body: some View {
        let matched = library.list.matching(controls)

        Group {
            // With no presets the menu is a dead end: a greyed "No presets yet" above the one item
            // anybody could choose, so every change of model took two clicks. The owner asked for
            // the panel straight away until there is a preset to offer. Its "Save as preset…" is
            // what makes the first one, and the menu comes back the moment it exists.
            if library.presets.isEmpty {
                Button { isOpen = true } label: {
                    settingsLabel(matched: matched)
                }
                .buttonStyle(.plain)
            } else {
                presetMenu(matched: matched)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(matched == nil ? "Agent settings" : "Agent settings, preset \(matched?.name ?? "")")
        .accessibilityLabel("Agent settings")
        .accessibilityValue(summary(matched: matched))
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            ComposerSettingsPanel(
                controls: controls,
                models: models,
                efforts: efforts,
                outputStyles: outputStyles,
                permissionModes: permissionModes,
                matchedPreset: matched,
                suggestedPresetName: "\(modelLabel) \(effortLabel)",
                onModel: onModel,
                onEffort: onEffort,
                onOutputStyle: onOutputStyle,
                onPermissionMode: onPermissionMode,
                onContextWindow: onContextWindow,
                onInteractionMode: onInteractionMode,
                onAdvisor: onAdvisor,
                onSavePreset: savePreset
            )
            .environment(\.fontScale, 1)
        }
        .task { await library.load(from: app.store) }
    }

    private func presetMenu(matched: ModelPreset?) -> some View {
        Menu {
            Section("Presets") {
                ForEach(library.presets) { preset in
                    // A toggle rather than a button, because the tick is the menu's to draw
                    // and a toggle is what asks for it. See `ComposerOptionMenu.rows`.
                    Toggle(isOn: Binding(
                        get: { matched?.id == preset.id },
                        set: { _ in MainActor.assumeIsolated { onPreset(preset) } }
                    )) {
                        Text(preset.name)
                        Text(presetSummary(preset))
                    }
                }
            }

            Divider()

            Button("Custom…") {
                // After the menu has closed, so the popover is not dismissed with it.
                DispatchQueue.main.async { isOpen = true }
            }

            Divider()

            Button("Manage presets…") {
                SettingsTabRequest.post(.presets)
                openSettings()
            }
        } label: {
            settingsLabel(matched: matched)
        }
        // The same three modifiers `ComposerOptionMenu` needs, for the reasons it gives.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func settingsLabel(matched: ModelPreset?) -> some View {
        ComposerControlLabel(
            systemImage: "slider.horizontal.3",
            text: isCompact ? nil : label(matched: matched),
            tint: Palette.textSecondary,
            isActive: isOpen,
            showsMenuIndicator: true,
            showsDot: matched == nil && !library.presets.isEmpty
        )
    }

    private var allModels: [ComposerOption] { models.flatMap(\.options) }

    private var modelLabel: String {
        ComposerOption.label(for: controls.model, in: allModels)
    }

    private var effortLabel: String {
        ComposerOption.label(for: controls.effort, in: efforts)
    }

    /// The preset's name when the composer is set to one, and otherwise the two choices that say
    /// most about what a turn costs. The dot beside a one-off is drawn by the label.
    private func label(matched: ModelPreset?) -> String {
        if let matched { return matched.name }
        return "\(modelLabel) · \(effortLabel)"
    }

    private func summary(matched: ModelPreset?) -> String {
        let base = "\(modelLabel), \(effortLabel), \(controls.permissionMode.label(on: controls.agentKind))"
        guard let matched else { return base }
        return "\(matched.name): \(base)"
    }

    /// The permission mode, which is the one field a preset's name most often leaves unsaid.
    private func presetSummary(_ preset: ModelPreset) -> String {
        preset.modeLabels.joined(separator: " · ")
    }

    private func savePreset(_ name: String) {
        guard let name = ModelPreset.cleanName(name) else { return }
        library.add(ModelPreset(name: name, controls: controls), in: app.store)
    }
}

private struct ComposerSettingsPanel: View {
    var controls: ComposerControls
    var models: [ComposerModelSection]
    var efforts: [ComposerOption]
    var outputStyles: [ComposerOption]
    var permissionModes: [ComposerOption]
    var matchedPreset: ModelPreset?
    var suggestedPresetName: String
    var onModel: @MainActor (String) -> Void
    var onEffort: @MainActor (String) -> Void
    var onOutputStyle: @MainActor (String) -> Void
    var onPermissionMode: @MainActor (String) -> Void
    var onContextWindow: @MainActor (Int) -> Void
    var onInteractionMode: @MainActor (InteractionMode) -> Void = { _ in }
    var onAdvisor: @MainActor (ChatAdvisor) -> Void = { _ in }
    var onSavePreset: @MainActor (String) -> Void

    /// The name being typed for a new preset, or nil while the row shows its button.
    @State private var presetName: String?
    @FocusState private var isNamingFocused: Bool
    /// Read each time the popover opens, so the switch in Settings is honoured without observing it.
    /// Starts from the last answer so the row does not pop in after the panel is drawn.
    @State private var isAdvisorEnabled = Self.lastKnownAdvisorEnabled
    private static var lastKnownAdvisorEnabled = true
    @Environment(AppModel.self) private var app

    private static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                settingRow("Model") { modelPicker }
                settingRow("Reasoning") {
                    optionPicker("Reasoning", selection: controls.effort, options: efforts, onSelect: onEffort)
                }

                if controls.offersOutputStyle {
                    settingRow("Output style") {
                        optionPicker(
                            "Output style",
                            selection: controls.outputStyle,
                            options: outputStyles,
                            onSelect: onOutputStyle
                        )
                    }
                }

                if controls.offersAdvisor, isAdvisorEnabled {
                    settingRow("Advisor") {
                        optionPicker(
                            "Advisor",
                            selection: controls.advisor.rawValue,
                            options: ChatAdvisor.allCases.map { ComposerOption(id: $0.rawValue, label: $0.label) },
                            onSelect: { id in onAdvisor(ChatAdvisor(stored: id)) }
                        )
                    }
                    .help("A stronger model consulted mid-turn. Each consultation rereads the whole conversation at its rate.")
                }

                if controls.offersInteractionMode {
                    settingRow("Work mode") {
                        if ComposerPlanningSupport.shared.isAvailable {
                            optionPicker(
                                "Work mode", selection: controls.interactionMode.rawValue,
                                options: InteractionMode.allCases.map { ComposerOption(id: $0.rawValue, label: $0.label) },
                                onSelect: { value in
                                    if let mode = InteractionMode(rawValue: value) { onInteractionMode(mode) }
                                }
                            )
                        } else if controls.interactionMode == .plan {
                            Button("Use Build") { onInteractionMode(.build) }
                        } else {
                            Text("Build")
                        }
                    }
                    if !ComposerPlanningSupport.shared.isAvailable {
                        Text(CodexPlanningCapability.explanation).font(Typo.caption)
                        Button("Check Again") { Task { await ComposerPlanningSupport.shared.checkAgain() } }
                            .disabled(ComposerPlanningSupport.shared.isChecking)
                    }
                }

                settingRow("Permissions") {
                    optionPicker(
                        "Permissions",
                        selection: controls.permissionMode.rawValue,
                        options: permissionModes,
                        onSelect: onPermissionMode
                    )
                }

                // Last, and only on the backend that has one. It is the coarsest of the five and
                // the one changed least often, and it is the only one that costs a reconnect when
                // it changes.
                //
                // **The reconnect is still not this row's business and the grants are.** Codex
                // being restarted is invisible and harmless, because the thread resumes; what a
                // person meets is a permission they already granted being asked again, with
                // nothing anywhere connecting that to the picker they touched. A tooltip rather
                // than a line, for `ArchivedWorkspaceFootprint.contents`'s reason: the row is one
                // line of a narrow panel and has no room for a sentence. The words are
                // `CodexContextWindow.changeConsequence`.
                if controls.offersContextWindow {
                    settingRow("Context window") { contextWindowPicker }
                        .help(CodexContextWindow.changeConsequence)
                }
            }
            .padding(Metrics.gutter)

            Hairline()

            presetRow
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Metrics.inset)
        }
        .frame(width: Self.width)
        .task {
            guard let store = app.store else { return }
            isAdvisorEnabled = await ChatAdvisor.isEnabledAppWide(in: store)
            Self.lastKnownAdvisorEnabled = isAdvisorEnabled
        }
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Metrics.spacing) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            Spacer(minLength: Metrics.spacing)

            content()
        }
        .frame(minHeight: Metrics.rowHeight)
    }

    private var modelPicker: some View {
        Picker("Model", selection: modelBinding) {
            ForEach(models) { section in
                Section(section.title) {
                    ForEach(section.options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    private func optionPicker(
        _ title: String,
        selection: String,
        options: [ComposerOption],
        onSelect: @escaping @MainActor (String) -> Void
    ) -> some View {
        Picker(title, selection: Binding(
            get: { selection },
            set: { id in MainActor.assumeIsolated { onSelect(id) } }
        )) {
            ForEach(options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    private var contextWindowPicker: some View {
        Picker("Context window", selection: contextWindowBinding) {
            ForEach(CodexContextWindow.options(including: controls.codexContextWindow), id: \.self) { tokens in
                Text(CodexContextWindow.label(for: tokens)).tag(tokens)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    private var contextWindowBinding: Binding<Int> {
        Binding(
            get: { controls.codexContextWindow },
            set: { tokens in MainActor.assumeIsolated { onContextWindow(tokens) } }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(get: { controls.model }, set: { id in MainActor.assumeIsolated { onModel(id) } })
    }

    /// "Save as preset…", which becomes a name field in place, or a line saying which preset these
    /// settings already are, so the same set cannot be saved twice by accident.
    @ViewBuilder
    private var presetRow: some View {
        if let presetName {
            HStack(spacing: Metrics.spacing) {
                TextField("Preset name", text: Binding(
                    get: { presetName },
                    set: { self.presetName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($isNamingFocused)
                .onSubmit(save)
                .onExitCommand { self.presetName = nil }

                Button("Cancel") { self.presetName = nil }
                    .controlSize(.small)
                Button("Save", action: save)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ModelPreset.cleanName(presetName) == nil)
            }
        } else if let matchedPreset {
            Text("Saved as preset \u{201C}\(matchedPreset.name)\u{201D}")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
        } else {
            Button("Save as preset…") {
                presetName = suggestedPresetName
                isNamingFocused = true
            }
            .linkButton()
            .font(Typo.label)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
        }
    }

    private func save() {
        guard let presetName, ModelPreset.cleanName(presetName) != nil else { return }
        onSavePreset(presetName)
        self.presetName = nil
    }
}
