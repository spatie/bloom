import SwiftUI
import BloomCore

/// The panel's own Settings screen: how the menu bar and the meters read. Everything else Bloom
/// does is one row away, in Bloom's own Settings window.
struct UsageSettingsView: View {
    @Environment(UsagePanelModel.self) private var model
    @Environment(\.usageScale) private var scale
    @AppStorage(SleepPrevention.settingKey) private var preventsSleep = SleepPrevention.isOnByDefault

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: scale.section) {
            UsageSettingsSection("Appearance") {
                UsageSettingsRow("Icon Style") { UsageChoicePicker(selection: $model.iconStyle) }
                UsageSettingsRow("Theme") { UsageChoicePicker(selection: $model.theme) }
                UsageSettingsRow("Density") { UsageChoicePicker(selection: $model.density) }
                UsageSettingsRow("Time Format") { UsageChoicePicker(selection: $model.timeFormat) }
            }

            UsageSettingsSection("Usage Display") {
                UsageSettingsRow("Show Usage As") { UsageChoicePicker(selection: $model.meterStyle) }
                UsageSettingsRow("Reset Times") { UsageChoicePicker(selection: $model.resetDisplay) }
                UsageSettingsRow("Always Show Pacing") { UsageSwitch(isOn: $model.alwaysShowsPacing) }
                    .usageTooltip("Show how you're pacing on every metric, not just ones near their limit")
            }

            UsageSettingsSection("Keep Awake") {
                UsageSettingsRow(SleepPrevention.menuItemTitle) { UsageSwitch(isOn: $preventsSleep) }
                Text(SleepPrevention.caveat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 0) {
                UsageLinkRow(symbol: "slider.horizontal.3", title: "Customize", detail: "Choose what's visible and where") {
                    model.navigate(to: .customize)
                }
                UsageLinkRow(symbol: "gear", title: "Bloom Settings", detail: "Everything else Bloom does") {
                    model.dismiss()
                    MenuBarStatusItem.openBloomSettings()
                }
            }
            .usageCard()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A captioned card of rows, the scaffold every section of Settings uses.
struct UsageSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.usageScale) private var scale

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.headerToCard) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.vertical, scale.cardGutter)
            .usageCard()
        }
    }
}

struct UsageSettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control
    @Environment(\.usageScale) private var scale

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: scale.label))
                .lineLimit(1)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, scale.controlRow)
    }
}

/// One of the panel's settings enums, as a menu picker. Segmented controls do not fit in 320
/// points, which is why OpenUsage uses menus here too.
protocol UsageChoice: CaseIterable, Hashable where AllCases: RandomAccessCollection {
    var title: String { get }
}

extension UsageMeterStyle: UsageChoice {}
extension UsageResetDisplay: UsageChoice {}
extension UsageTimeFormat: UsageChoice {}
extension MenuBarIconStyle: UsageChoice {}
extension UsageDensity: UsageChoice {}
extension UsagePanelTheme: UsageChoice {}

struct UsageChoicePicker<Choice: UsageChoice>: View {
    @Binding var selection: Choice

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(Choice.allCases), id: \.self) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

struct UsageSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}
