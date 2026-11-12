import SwiftUI
import BloomCore

/// The root owns defaults so switching panes preserves edits and serialises their writes.
struct ModelSettingsView: View {
    @Environment(AppModel.self) private var app
    @Binding var defaults: AppDefaults
    @State private var outputStyles = ComposerOutputStyleCatalog()

    var body: some View {
        Form {
            Section {
                SettingsRow("New sessions") {
                    ModelAndEffortPickers(
                        model: $defaults.model, effort: $defaults.effort, backend: $defaults.backend
                    )
                }
                SettingsRow("Reviews") {
                    ModelAndEffortPickers(
                        model: $defaults.reviewModel, effort: $defaults.reviewEffort,
                        backend: $defaults.reviewBackend
                    )
                }
            } header: {
                Text("Models")
            } footer: {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    Text("Each row selects a model and reasoning effort. Project model settings take priority. Existing sessions keep their settings.")
                        .settingsFootnote()
                    // Said here, because otherwise this row looks broken: a default preset
                    // outranks it, and new sessions would ignore whatever it is set to.
                    if let preset = ModelPresetLibrary.shared.list.defaultPreset {
                        Text("New sessions start on the default preset, \u{201C}\(preset.name)\u{201D}, rather than on this row. Change that under Model Presets.")
                            .settingsFootnote()
                    }
                }
            }

            Section("New session behaviour") {
                Picker("Open new chats in", selection: $defaults.terminalChat) {
                    Text("Bloom chat").tag(false)
                    Text("CLI chat").tag(true)
                }
                Text("Used for new chats, panes and workspaces. CLI chat supports Claude Code and Codex; other agents use Bloom chat.")
                    .settingsFootnote()
                Toggle("Start in plan mode", isOn: $defaults.planMode)
                Toggle("Start in fast mode", isOn: $defaults.fastMode)
            }

            Section("Claude Code") {
                Picker(selection: $defaults.outputStyle) {
                    ForEach(outputStyles.options(includingCurrent: defaults.outputStyle)) { option in
                        Text(option.label).tag(option.id)
                    }
                } label: {
                    Text("Output style")
                    Text(outputStyles.detail(of: defaults.outputStyle) ?? "How new Claude Code sessions write.")
                }
                Toggle("Advisor", isOn: $defaults.advisorEnabled)
                if defaults.advisorEnabled {
                    Picker("Default advisor model", selection: $defaults.advisor) {
                        ForEach(ClaudeAdvisor.allCases) { advisor in
                            Text(advisor.label).tag(advisor)
                        }
                    }
                }
                Text(defaults.advisorEnabled
                     ? "A stronger model Claude Code can consult during a turn, which uses more tokens. It is consulted only when it is at least as capable as the chat's own model. Not set leaves it to Claude Code's own settings. You can pick another, or none, for each chat in the composer."
                     : "Claude Code chats never consult an advisor, whatever was picked for them in the composer.")
                    .settingsFootnote()
            }

            Section {
                Picker("Context window", selection: $defaults.codexContextWindow) {
                    ForEach(CodexContextWindow.options(including: defaults.codexContextWindow), id: \.self) { tokens in
                        Text(CodexContextWindow.label(for: tokens)).tag(tokens)
                    }
                }
            } header: {
                Text("Codex")
            } footer: {
                Text("Overrides the context size reported to new Codex sessions. Use the model default unless you need a specific size.")
                    .settingsFootnote()
            }
        }
        .settingsForm()
        .task {
            ComposerModelCatalog.shared.load()
            await ModelPresetLibrary.shared.load(from: app.store)
            await outputStyles.refreshIfStale(project: nil)
        }
    }
}

/// The model and effort pair appears three times, twice on this screen and once in the preset
/// editor, and has to stay identical in all of them. Both lists come from `ComposerModelCatalog`,
/// which is the composer's own menu: one section per backend, Codex's models fetched rather than
/// written down, and each Codex model's own set of reasoning levels. Building a second list here is how the screen came to offer four Claude Code
/// models while every chat could be moved to a GPT one.
struct ModelAndEffortPickers: View {
    @Binding var model: String
    @Binding var effort: String
    /// Written by the model picker, never picked on its own. Choosing a model out of the Codex
    /// section IS choosing Codex, here for the same reason as in the composer: a model id already
    /// names its backend, and a second menu saying so would be a second thing to keep in step.
    /// See `ComposerControls.agentKind`.
    @Binding var backend: AgentKind

    private var catalog: ComposerModelCatalog { .shared }

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            Picker("Model", selection: chosenModel) {
                ForEach(catalog.sections(includingCurrent: model, on: backend)) { section in
                    Section(section.title) {
                        ForEach(section.options) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()

            Picker("Effort", selection: $effort) {
                // `adding` for the reason its own head gives, and this screen is the case it
                // warns about: the levels a Codex model takes are the model's, so a stored
                // `ultra` on a machine whose list has not arrived is an id no row carries. A
                // picker that dropped it would show nothing selected and turn the first press
                // into a one-way door out of the value in force.
                ForEach(ComposerOption.adding([effort], to: efforts)) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var efforts: [ComposerOption] {
        catalog.efforts(for: backend, model: model)
    }

    /// Three values move together, exactly as they do in the composer's footer: the model, the
    /// backend it names, and the effort, which has to land on something the new model takes.
    ///
    /// A binding that writes rather than a plain `$model` with an `onChange` beside it, because
    /// this must fire on a press and on nothing else. `onChange` also fires when the screen loads
    /// its values out of the store, which would let a list that has not been fetched yet decide a
    /// backend the owner already chose.
    private var chosenModel: Binding<String> {
        Binding(get: { model }, set: { id in MainActor.assumeIsolated { choose(id) } })
    }

    private func choose(_ id: String) {
        let kind = catalog.backend(ofModel: id, current: backend)
        model = id
        backend = kind
        effort = catalog.resolvedEffort(effort, for: kind, model: id)
    }
}
