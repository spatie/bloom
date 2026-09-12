import SwiftUI
import BloomCore

/// Every provider's card, then the Keep Awake card and the agents, in the panel's own card style.
///
/// Fed with plain values rather than the app model, so the snapshot gallery can draw any state the
/// real accounts on this machine cannot be asked to be in.
struct UsageDashboardView: View {
    let metrics: [AgentKind: [UsageMetric]]
    let accounts: [AgentKind: AgentAccount]
    /// The oldest reading behind each provider's card, which decides whether it says "Outdated".
    let observedAt: [AgentKind: Date]
    let isRefreshing: Bool
    let agentSections: [MenuBarSummary.Section]
    let runningCount: Int
    let now: Date
    var onOpenWorkspace: (WorkspaceID) -> Void = { _ in }
    /// The two cards about this Mac rather than about an allowance. Off in the gallery, which is a
    /// page about the limits.
    var showsMachineCards = true

    @Environment(UsagePanelModel.self) private var model
    @Environment(\.usageScale) private var scale

    var body: some View {
        let sections = model.layout.sections(for: metrics)
        VStack(alignment: .leading, spacing: scale.section) {
            // Keep Awake first, above the limits. It is the one card here somebody comes to the
            // panel to *change* rather than to read, so it sits where the pointer already is.
            if showsMachineCards {
                KeepAwakeCard(runningCount: runningCount, now: now)
            }
            if sections.isEmpty {
                empty
            }
            ForEach(sections) { section in
                UsageProviderSectionView(
                    section: section,
                    account: accounts[section.provider],
                    observedAt: observedAt[section.provider],
                    isRefreshing: isRefreshing,
                    now: now
                )
            }
            if showsMachineCards {
                UsageAgentsCard(sections: agentSections, onOpen: onOpenWorkspace)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, scale.contentTop)
        .padding(.bottom, 12)
    }

    private var empty: some View {
        Text(metrics.isEmpty ? Self.emptySentence : Self.allHiddenSentence)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
            .usageCard()
    }

    /// Neither CLI installed, neither signed in, or the first second of a launch. It names the
    /// mechanism, because "nothing reported yet" on its own reads as broken.
    static let emptySentence =
        "Nothing reported yet. Bloom asks Claude Code and Codex for their limits every minute, "
        + "so this fills in shortly after either one is installed and signed in."

    static let allHiddenSentence = "Every provider is switched off. Turn one on in Customize to see its limits."

    static func oldestReadings(_ quotas: [AgentQuota]) -> [AgentKind: Date] {
        Dictionary(grouping: quotas, by: \.provider).compactMapValues { $0.map(\.observedAt).min() }
    }
}

/// The workspaces an agent is blocked in, working in or has finished in, as the menu used to list
/// them, one click from each.
struct UsageAgentsCard: View {
    let sections: [MenuBarSummary.Section]
    let onOpen: (WorkspaceID) -> Void
    @Environment(\.usageScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.headerToCard) {
            UsageSectionHeader(symbol: "point.3.connected.trianglepath.dotted", title: "Agents")
            VStack(alignment: .leading, spacing: 0) {
                if sections.isEmpty {
                    Text(MenuBarSummary.emptyTitle)
                        .font(.system(size: scale.supporting))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, scale.textRowPadding)
                }
                ForEach(sections, id: \.heading) { section in
                    Text(section.heading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, scale.textRowPadding)
                        .padding(.bottom, 2)
                    ForEach(section.workspaces) { workspace in
                        UsageHoverRow {
                            onOpen(workspace.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: section.symbolName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                    .accessibilityLabel(section.label)
                                Text(workspace.name)
                                    .font(.system(size: scale.supporting + 1))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, scale.cardGutter)
            .usageCard()
        }
    }
}

/// Whether the Mac will stay awake, and the controls to make it: for a while, until a time, until
/// stopped, or whenever an agent runs.
///
/// **It says the state in words, in the first line, because the old switch did not.** A checkmark
/// on "Prevent Sleep While Agents Run" said what somebody had asked for, not whether the machine
/// was being held open right then, and "is it on" was the question.
struct KeepAwakeCard: View {
    let runningCount: Int
    let now: Date
    @Environment(UsagePanelModel.self) private var model
    @Environment(\.usageScale) private var scale
    @AppStorage(SleepPrevention.settingKey) private var whileAgentsRun = SleepPrevention.isOnByDefault
    @State private var choosesTime = false
    @State private var until = Date().addingTimeInterval(3600)

    private var keepAwake: KeepAwakeModel { KeepAwakeModel.shared }

    var body: some View {
        let status = KeepAwake.status(
            session: keepAwake.session,
            whileAgentsRun: whileAgentsRun,
            runningCount: runningCount,
            at: now,
            clock: model.timeFormat
        )
        VStack(alignment: .leading, spacing: scale.headerToCard) {
            UsageSectionHeader(symbol: KeepAwake.menuBarSymbol, title: KeepAwake.title)
            VStack(alignment: .leading, spacing: 0) {
                // The state on a line of its own, with only Stop beside it. Stop and the duration
                // menu used to share this row, which left the headline a third of the card and
                // broke "Keeping this Mac awake" over three lines.
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: status.isOn ? KeepAwake.menuBarSymbol : "moon.zzz.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(status.isOn ? UsageInk.normal : Color.secondary)
                        .frame(width: Self.iconWidth)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.headline)
                            .font(.system(size: scale.label, weight: .semibold))
                            .lineLimit(1)
                        Text(status.detail)
                            .font(.system(size: scale.supporting))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    // One click, which is what Amphetamine's menu gets right: the switch starts a
                    // session that runs until it is turned off, and the menu under it is for the
                    // times somebody wants it to end by itself.
                    Toggle(KeepAwake.title, isOn: Binding(
                        get: { keepAwake.session != nil },
                        set: { wanted in
                            withAnimation(UsageMotion.spring) {
                                if wanted { keepAwake.start(for: nil) } else { keepAwake.stop() }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .usageTooltip(keepAwake.session == nil
                        ? "Keep this Mac awake until you turn it off"
                        : "Stop keeping this Mac awake")
                }
                .padding(.horizontal, 14)
                .padding(.top, scale.barRowPadding)

                // The choices under the words they change, lined up with the text rather than the
                // icon, so the card reads top to bottom: what is happening, then what to do.
                HStack(spacing: 8) {
                    startMenu
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14 + Self.iconWidth + 10)
                .padding(.trailing, 14)
                .padding(.top, 8)
                .padding(.bottom, scale.barRowPadding)

                if choosesTime {
                    untilRow
                        .transition(.opacity)
                }

                Rectangle()
                    .fill(.separator)
                    .frame(height: 0.5)
                    .padding(.horizontal, 14)

                HStack(spacing: 10) {
                    Text(SleepPrevention.menuItemTitle.replacingOccurrences(of: "Prevent Sleep ", with: ""))
                        .font(.system(size: scale.supporting, weight: .semibold))
                    Spacer(minLength: 8)
                    Toggle(SleepPrevention.menuItemTitle, isOn: $whileAgentsRun)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, scale.controlRow)
                .usageTooltip(SleepPrevention.caveat)
            }
            .padding(.vertical, scale.cardGutter)
            .usageCard()
        }
    }

    private static let iconWidth: CGFloat = 20

    private var startMenu: some View {
        Menu {
            Button("Indefinitely") { keepAwake.start(for: nil) }
            Menu("Minutes") {
                ForEach(KeepAwake.minuteChoices, id: \.self) { minutes in
                    Button(KeepAwake.label(minutes: minutes)) { keepAwake.start(for: TimeInterval(minutes * 60)) }
                }
            }
            Menu("Hours") {
                ForEach(KeepAwake.hourChoices, id: \.self) { hours in
                    Button(KeepAwake.label(hours: hours)) { keepAwake.start(for: TimeInterval(hours * 3600)) }
                }
            }
            Divider()
            Button("Until a Time\u{2026}") {
                until = keepAwake.session?.until ?? Date().addingTimeInterval(3600)
                withAnimation(UsageMotion.spring) { choosesTime = true }
            }
        } label: {
            Text(keepAwake.session == nil ? "Keep Awake For\u{2026}" : "Change Duration\u{2026}")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private var untilRow: some View {
        HStack(spacing: 8) {
            DatePicker("Until", selection: $until, displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .font(.system(size: scale.supporting))
            Spacer(minLength: 4)
            Button("Keep Awake") {
                keepAwake.start(until: KeepAwake.nextOccurrence(of: until, after: Date()))
                withAnimation(UsageMotion.spring) { choosesTime = false }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            Button {
                withAnimation(UsageMotion.spring) { choosesTime = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Cancel")
        }
        .padding(.leading, 14 + Self.iconWidth + 10)
        .padding(.trailing, 14)
        .padding(.bottom, scale.barRowPadding)
    }
}
