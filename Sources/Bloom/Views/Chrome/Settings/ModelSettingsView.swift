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
    /// reason is worth writing down: this default is chosen before any backend is, so the rows
    /// are in Claude Code's vocabulary, and Claude Code's name for that mode is Auto. Offering
    /// both would draw two rows reading "Auto" in one menu. A Codex chat reaches it from the
    /// composer, which is where a chat picks a backend at all.
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
                        effort: $defaults.effort
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
                        effort: $defaults.reviewEffort
                    )
                } label: {
                    Text("Review model")
                }
            }

            Section {
                // Claude Code only, and nothing here says so, because nothing here mentions a
                // backend at all: the model list above is Claude's too. The composer is where a
                // chat picks a backend, and that is where this picker disappears for Codex.
                Picker(selection: $defaults.outputStyle) {
                    ForEach(outputStyles.options(includingCurrent: defaults.outputStyle)) { option in
                        Text(option.label).tag(option.id)
                    }
                } label: {
                    Text("Default output style")
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

                // Codex only, and this one says so, unlike the output style above it. The output
                // style sits under a model list that is already Claude Code's, so the section
                // reads as that backend's throughout; this row is the only Codex setting on the
                // screen, and a "Context window" with no backend on it would read as a claim about
                // the model list above.
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
/// lists come from `ComposerOption` so they cannot drift from the composer's own menus.
private struct ModelAndEffortPickers: View {
    @Binding var model: String
    @Binding var effort: String

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            Picker("Model", selection: $model) {
                ForEach(ComposerOption.models) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .fixedSize()

            Picker("Effort", selection: $effort) {
                ForEach(ComposerOption.efforts) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}
