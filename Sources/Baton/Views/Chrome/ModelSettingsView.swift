import SwiftUI
import BatonCore

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

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ModelAndEffortPickers(
                        model: $defaults.model,
                        effort: $defaults.effort
                    )
                } label: {
                    SettingLabel(title: "Default model", subtitle: "Model for new sessions")
                }

                LabeledContent {
                    ModelAndEffortPickers(
                        model: $defaults.reviewModel,
                        effort: $defaults.reviewEffort
                    )
                } label: {
                    SettingLabel(title: "Review model", subtitle: "Model for code reviews")
                }
            }

            Section {
                Picker(selection: $defaults.permissionMode) {
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    SettingLabel(
                        title: "Default permission mode",
                        subtitle: "How much a new session may do without asking"
                    )
                }

                Toggle(isOn: $defaults.planMode) {
                    SettingLabel(
                        title: "Default to plan mode",
                        subtitle: "Start new sessions in plan mode"
                    )
                }

                Toggle(isOn: $defaults.fastMode) {
                    SettingLabel(
                        title: "Default to fast mode",
                        subtitle: "Start new sessions in fast mode"
                    )
                }
            }

            Section {
                Text(
                    "A repository that pins a model in its own settings file wins over these. "
                    + "Sessions that already exist keep whatever they were opened with."
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .formStyle(.grouped)
        .task {
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

/// Conductor's rows carry a second line of explanation under the title, and the explanation is
/// what makes "fast mode" mean anything to someone reading it for the first time.
private struct SettingLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cornerSmall / 2) {
            Text(title)
                .foregroundStyle(Palette.textPrimary)
            Text(subtitle)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
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
