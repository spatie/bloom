import SwiftUI
import BloomCore

/// One calm entry point for the settings that qualify the next agent turn.
///
/// Model, effort, output style, permissions and fast mode used to compete as five adjacent
/// controls. They belong to one decision, so the footer now keeps the model visible and moves the
/// complete set into one native settings panel.
struct ComposerSettingsPicker: View {
    var controls: ComposerControls
    var models: [ComposerModelSection]
    var efforts: [ComposerOption]
    var outputStyles: [ComposerOption]
    var permissionModes: [ComposerOption]
    var isCompact: Bool
    var onModel: @MainActor (String) -> Void
    var onEffort: @MainActor (String) -> Void
    var onOutputStyle: @MainActor (String) -> Void
    var onPermissionMode: @MainActor (String) -> Void
    var onFastMode: @MainActor (Bool) -> Void

    @State private var isOpen = false

    var body: some View {
        Button { isOpen = true } label: {
            ComposerControlLabel(
                systemImage: "slider.horizontal.3",
                text: isCompact ? nil : modelLabel,
                tint: Palette.textSecondary,
                isActive: isOpen,
                showsMenuIndicator: true
            )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .help("Agent settings")
        .accessibilityLabel("Agent settings")
        .accessibilityValue(summary)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            ComposerSettingsPanel(
                controls: controls,
                models: models,
                efforts: efforts,
                outputStyles: outputStyles,
                permissionModes: permissionModes,
                onModel: onModel,
                onEffort: onEffort,
                onOutputStyle: onOutputStyle,
                onPermissionMode: onPermissionMode,
                onFastMode: onFastMode
            )
            .environment(\.fontScale, 1)
        }
    }

    private var allModels: [ComposerOption] { models.flatMap(\.options) }

    private var modelLabel: String {
        ComposerOption.label(for: controls.model, in: allModels)
    }

    private var summary: String {
        let effort = ComposerOption.label(for: controls.effort, in: efforts)
        return "\(modelLabel), \(effort), \(controls.permissionMode.label)"
    }
}

private struct ComposerSettingsPanel: View {
    var controls: ComposerControls
    var models: [ComposerModelSection]
    var efforts: [ComposerOption]
    var outputStyles: [ComposerOption]
    var permissionModes: [ComposerOption]
    var onModel: @MainActor (String) -> Void
    var onEffort: @MainActor (String) -> Void
    var onOutputStyle: @MainActor (String) -> Void
    var onPermissionMode: @MainActor (String) -> Void
    var onFastMode: @MainActor (Bool) -> Void

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

                settingRow("Permissions") {
                    optionPicker(
                        "Permissions",
                        selection: controls.permissionMode.rawValue,
                        options: permissionModes,
                        onSelect: onPermissionMode
                    )
                }
            }
            .padding(Metrics.gutter)

            Hairline()

            HStack(spacing: Metrics.spacing) {
                Text("Prefer faster replies")
                    .font(Typo.label)

                Spacer(minLength: Metrics.spacing)

                Toggle("Prefer faster replies", isOn: fastBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.inset)
        }
        .frame(width: Self.width)
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

    private var modelBinding: Binding<String> {
        Binding(get: { controls.model }, set: { id in MainActor.assumeIsolated { onModel(id) } })
    }

    private var fastBinding: Binding<Bool> {
        Binding(
            get: { controls.isFastMode },
            set: { value in MainActor.assumeIsolated { onFastMode(value) } }
        )
    }
}
