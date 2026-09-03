import SwiftUI
import BloomCore

/// The "Models" tab: what a brand new session starts out as.
///
/// Every control here writes through `Store.setSetting`, and `ComposerView.prepare()` reads them
/// back. That loop is the whole point of the screen. The previous Agent tab wrote the same three
/// values and nothing ever read them, which is worse than having no controls at all, because the
/// user believes a choice took effect.
///
/// Reads and writes go through the `Store` actor, so the values are loaded once into `@State` in
/// `.task` and written back on change. Nothing in `body` touches the store or the file system.
struct ModelSettingsView: View {
    /// What the app-wide default may be set to. Approve for me is the one mode left out, and the
    /// reason is worth writing down: the rows are in Claude Code's vocabulary, and Claude Code's
    /// name for that mode is Auto, so offering both would draw two rows reading "Auto" in one
    /// menu. A Codex chat reaches it from the composer, which is where a chat's own mode is set.
    ///
    /// The vocabulary stays Claude Code's now that the model above can name Codex, because this
    /// one picker sits under two model rows that are free to be on different backends: an owner
    /// who works in Codex and has reviews done by Claude Code would otherwise need two permission
    /// pickers to be told which words apply. A mode the backend a chat lands on has no row for
    /// lands on its nearest, which is `PermissionMode.nearest(on:)`, and it is applied where the
    /// chat is opened rather than trusted to this screen: Plan plus a Codex model is Read only.
    private static let defaultablePermissionModes: [PermissionMode] =
        PermissionMode.allCases.filter { $0 != .autoReview }

    @Environment(AppModel.self) private var app

    @State private var defaults = AppDefaults()
    /// Guards the first write. Assigning `@State` inside `.task` fires every `onChange`, and
    /// saving there would overwrite real settings with the fallbacks on every window open.
    @State private var isLoaded = false
    /// The styles this machine has. No project, because this screen is about every repository at
    /// once: a style a single checkout defines is offered in that checkout's composer and would be
    /// a setting nothing could honour here.
    @State private var outputStyles = ComposerOutputStyleCatalog()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ModelAndEffortPickers(
                        model: $defaults.model,
                        effort: $defaults.effort,
                        backend: $defaults.backend
                    )
                } label: {
                    // No second line under either of these. "Model for new sessions" under a label
                    // reading "Default model" is the label again in different words, and a caption
                    // that says nothing teaches the reader to skip the ones that do.
                    Text("Default model")
                }

                LabeledContent {
                    ModelAndEffortPickers(
                        model: $defaults.reviewModel,
                        effort: $defaults.reviewEffort,
                        backend: $defaults.reviewBackend
                    )
                } label: {
                    Text("Review model")
                }
            }

            Section {
                // Claude Code only, and it says so in its own label now, because the sentence
                // that used to excuse the silence has stopped being true: the model list above
                // has a Codex section in it, so "nothing here mentions a backend" no longer
                // describes this screen.
                //
                // Named rather than hidden, which is the other option and was rejected twice
                // over. A row that disappears when the default model moves to Codex takes a
                // stored style with it, leaving a value that is still in force for every Claude
                // Code chat and no longer has a control; and the review model can be on the other
                // backend from the default one, so there is no single backend for this row to
                // appear and disappear with. The context window row at the foot of this section
                // settled the same question the same way, and two rows that name their backends
                // read as a pair where one alone read as an exception.
                Picker(selection: $defaults.outputStyle) {
                    ForEach(outputStyles.options(includingCurrent: defaults.outputStyle)) { option in
                        Text(option.label).tag(option.id)
                    }
                } label: {
                    Text("Claude Code output style")
                    Text(outputStyles.detail(of: defaults.outputStyle) ?? "How new sessions write")
                }

                Picker(selection: $defaults.permissionMode) {
                    ForEach(Self.defaultablePermissionModes, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Text("Default permission mode")
                    Text("How much a new session may do without asking")
                }

                Toggle("Start new sessions in plan mode", isOn: $defaults.planMode)

                Toggle("Start new sessions in fast mode", isOn: $defaults.fastMode)

                // Codex only, and it says so for the same reason the output style above it now
                // does: a "Context window" with no backend on it would read as a claim about
                // every model in the list above, and half of that list is Claude Code's.
                Picker(selection: $defaults.codexContextWindow) {
                    ForEach(
                        CodexContextWindow.options(including: defaults.codexContextWindow),
                        id: \.self
                    ) { tokens in
                        Text(CodexContextWindow.label(for: tokens)).tag(tokens)
                    }
                } label: {
                    Text("Codex context window")
                    Text("How large a new Codex session is told the model's window is")
                }
            } footer: {
                // A footer rather than a section of its own. A group holding nothing but a
                // sentence draws a card around the sentence, which makes an aside look like a
                // setting the user has failed to find the control for.
                Text(
                    "A repository that pins a model in its own settings file wins over these. "
                    + "Sessions that already exist keep whatever they were opened with."
                )
                .settingsFootnote()
            }
        }
        .settingsForm()
        .task {
            // Codex's models are fetched, so the section is empty until this returns and the two
            // pickers have to be right before it does. They are: a stored id the list does not
            // hold stays on the list through `ComposerOption.adding`, so a machine that is
            // offline, or that has no Codex on it at all, shows and keeps whatever was chosen.
            ComposerModelCatalog.shared.load()
            await outputStyles.refreshIfStale(project: nil)
            guard let store = app.store else { return }
            defaults = await AppDefaults.load(from: store)
            isLoaded = true
        }
        .onChange(of: defaults) { _, updated in
            guard isLoaded, let store = app.store else { return }
            Task { await updated.save(to: store) }
        }
    }
}

/// The model and effort pair appears twice and has to stay identical in both places, and both
/// lists come from `ComposerModelCatalog`, which is the composer's own menu: one section per
/// backend, Codex's models fetched rather than written down, and each Codex model's own set of
/// reasoning levels. Building a second list here is how the screen came to offer four Claude Code
/// models while every chat could be moved to a GPT one.
private struct ModelAndEffortPickers: View {
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
