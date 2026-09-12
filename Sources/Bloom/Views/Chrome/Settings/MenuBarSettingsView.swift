import SwiftUI
import BloomCore

/// Settings ▸ Menu Bar: what the menu bar item shows, in which order, and what holds the Mac awake.
///
/// **Here rather than in the menu, because a menu cannot do either of the two things this needs.**
/// An open `NSMenu` runs its own tracking loop, so a row cannot be dragged and a hover cannot be
/// read; a window can do both. The menu offers arrows to move a provider, which is the one gesture
/// it can manage, and everything else about the item lives on this pane.
struct MenuBarSettingsView: View {
    let app: AppModel

    @AppStorage(MenuBarStatusItem.settingKey) private var showsItem = MenuBarStatusItem.isOnByDefault
    @State private var model = UsageMenuModel.shared
    @State private var keepAwake = KeepAwakeModel.shared
    @State private var sleepSwitch = SleepSwitch.shared
    @State private var choosing: AgentKind?
    @State private var dragging: AgentKind?

    /// One provider's row, which is two lines of text with controls beside it.
    private static let rowHeight: CGFloat = 42

    private var metrics: [AgentKind: [UsageMetric]] {
        UsageCatalogue.metrics(quotas: app.quotas, accounts: app.accounts)
    }

    var body: some View {
        Form {
            Section {
                preview
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            }

            Section("The menu bar item") {
                // Never disabled, whatever is off below it: this switch is the way back. It was
                // inside the `disabled` that covers the rest, which left somebody who turned the
                // item off with a greyed out switch and no way to return.
                Toggle("Show Bloom in the menu bar", isOn: $showsItem)
                Group {
                    Toggle("Show usage figures", isOn: $model.showsUsage)
                    Picker("Figures", selection: $model.iconStyle) {
                        ForEach(MenuBarIconStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Count", selection: $model.meterStyle) {
                        ForEach(UsageMeterStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(!showsItem)
            }

            Section("Providers") {
                // A `List` with `onMove` rather than `draggable` and `dropDestination`, which is
                // what this was: hand rolled drag and drop gave a bare text label for a drag image,
                // no gap where the row would land, and rows that snapped into place. A list does
                // all three itself, the way every other reorderable list on the Mac does.
                List {
                    ForEach(model.layout.orderedProviders(), id: \.self) { provider in
                        providerRow(provider)
                    }
                    .onMove { offsets, destination in
                        model.update { $0.moveProviders(fromOffsets: offsets, toOffset: destination) }
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .frame(height: Self.rowHeight * CGFloat(model.layout.orderedProviders().count))
                .listRowInsets(EdgeInsets())

                Text("Drag to reorder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(!showsItem || !model.showsUsage)

            Section("Keep Awake") {
                Toggle("Show a cup while kept awake", isOn: $model.showsCup)
                    .disabled(!showsItem)
                Toggle(isOn: $keepAwake.keepsLidClosed) {
                    Text("Keep awake with the lid closed")
                    Text("Needs Bloom's helper, approved once in System Settings.")
                }
                switch sleepSwitch.standing {
                case .ready:
                    Label(
                        "Bloom's helper is approved. Sleep is restored when the session ends, or if Bloom crashes.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                case .needsApproval:
                    HStack {
                        Text("Allow Bloom's helper to finish switching this on.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") { sleepSwitch.openApprovalSettings() }
                    }
                case .unavailable(let reason):
                    Text("This build cannot install the helper: \(reason)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { sleepSwitch.refresh() }
    }

    // MARK: - The live preview

    /// The item itself, drawn from the same renderer the menu bar uses, so this pane cannot
    /// disagree with the thing it is configuring.
    private var preview: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if showsItem {
                    if let image = stripImage {
                        Image(nsImage: image)
                            .renderingMode(.template)
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.white)
                    }
                    if model.showsCup {
                        Image(systemName: KeepAwake.menuBarSymbol)
                            .foregroundStyle(.white.opacity(keepAwake.isActive ? 1 : 0.35))
                    }
                } else {
                    Text("No menu bar item")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text("What the menu bar shows right now")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var stripImage: NSImage? {
        guard model.showsUsage else { return nil }
        let strip = MenuBarUsageStrip.make(layout: model.layout, metrics: metrics, options: model.options)
        guard !strip.isEmpty else { return nil }
        return MenuBarStripImage.image(for: strip, style: model.iconStyle)
    }

    // MARK: - Providers

    private func providerRow(_ provider: AgentKind) -> some View {
        let available = metrics[provider] ?? []
        let starred = model.layout.orderedMetrics(available).filter { model.layout.isPinned($0.id) }
        return HStack(spacing: 10) {
            ProviderMarkView(provider: provider)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.label)
                Text(menuBarSummary(starred: starred, available: available))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Choose\u{2026}") { choosing = provider }
                .disabled(available.isEmpty)
                .popover(isPresented: Binding(
                    get: { choosing == provider },
                    set: { shown in choosing = shown ? provider : nil }
                )) {
                    starPicker(provider, available: available)
                }
            Toggle("Show \(provider.label)", isOn: Binding(
                get: { model.layout.isEnabled(provider) },
                set: { value in model.update { $0.setEnabled(value, for: provider) } }
            ))
            .labelsHidden()
        }
        .opacity(model.layout.isEnabled(provider) ? 1 : 0.55)
    }

    private func menuBarSummary(starred: [UsageMetric], available: [UsageMetric]) -> String {
        if available.isEmpty { return "Nothing reported yet" }
        if starred.isEmpty { return "Menu bar: mark only" }
        return "Menu bar: " + starred.map(\.title).joined(separator: ", ")
    }

    /// Which of a provider's metrics ride in the menu bar. Two at most: two figures stack into the
    /// height of the menu bar and a third would need a row the bar does not have.
    private func starPicker(_ provider: AgentKind, available: [UsageMetric]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider.label)
                .font(.headline)
            ForEach(model.layout.orderedMetrics(available)) { metric in
                let isPinned = model.layout.isPinned(metric.id)
                Toggle(isOn: Binding(
                    get: { isPinned },
                    set: { _ in model.togglePin(metric) }
                )) {
                    Text(metric.title)
                }
                .disabled(!isPinned && model.layout.pins.filter {
                    UsageCatalogue.providerPart(of: $0) == provider.rawValue
                }.count >= UsageLayout.maximumPinsPerProvider)
            }
            Text(UsageLayout.pinDenial)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 240)
    }
}
