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
                    Text("Default model")
                    Text("Model for new sessions")
                }

                LabeledContent {
                    ModelAndEffortPickers(
                        model: $defaults.reviewModel,
                        effort: $defaults.reviewEffort
                    )
                } label: {
                    Text("Review model")
                    Text("Model for code reviews")
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
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Text("Default permission mode")
                    Text("How much a new session may do without asking")
                }

                Toggle(isOn: $defaults.planMode) {
                    Text("Default to plan mode")
                    Text("Start new sessions in plan mode")
                }

                Toggle(isOn: $defaults.fastMode) {
                    Text("Default to fast mode")
                    Text("Start new sessions in fast mode")
                }
            } footer: {
                // A footer rather than a section of its own. A group holding nothing but a
                // sentence draws a card around the sentence, which makes an aside look like a
                // setting the user has failed to find the control for.
                Text(
                    "A repository that pins a model in its own settings file wins over these. "
                    + "Sessions that already exist keep whatever they were opened with."
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
