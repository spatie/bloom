import SwiftUI
import BloomCore

/// The strip along the bottom of the panel: which Bloom this is, when it next asks the providers
/// (a button that asks now), and the Options menu.
struct UsagePanelFooter: View {
    let app: AppModel
    @Environment(UsagePanelModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Bloom \(Self.version)")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button {
                        model.refresh()
                    } label: {
                        if app.isAskingForQuotas {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Updating\u{2026}")
                            }
                        } else {
                            Text(UsageFormat.nextUpdate(
                                lastAskedAt: app.lastQuotaAskAt,
                                interval: QuotaPollSchedule.interval,
                                at: context.date
                            ))
                            .contentTransition(.numericText())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(app.isAskingForQuotas)
                    .usageTooltip("Refresh now (\u{2318}R)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Spacer(minLength: 8)

            if model.screen == .dashboard {
                UsageOptionsMenu(app: app)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: Rectangle())
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Everything the panel does that is not a row: its two other screens, screenshots, updates, the
/// main window, and quitting.
struct UsageOptionsMenu: View {
    let app: AppModel
    @Environment(UsagePanelModel.self) private var model

    var body: some View {
        Menu {
            Button("Customize", systemImage: "slider.horizontal.3") { model.navigate(to: .customize) }
            Button("Settings", systemImage: "gearshape") { model.navigate(to: .settings) }
            Divider()
            Menu("Copy Screenshot", systemImage: "square.and.arrow.up") {
                let sections = model.layout.sections(
                    for: UsageCatalogue.metrics(quotas: app.quotas, accounts: app.accounts)
                )
                if sections.isEmpty {
                    Button("No Providers Reporting") {}
                        .disabled(true)
                }
                ForEach(sections) { section in
                    Button(section.provider.label) {
                        model.copyScreenshot(of: section, account: app.accounts[section.provider], now: Date())
                    }
                }
            }
            Button("Check for Updates\u{2026}", systemImage: "arrow.triangle.2.circlepath") {
                model.dismiss()
                SoftwareUpdater.shared.checkForUpdates()
            }
            .disabled(!SoftwareUpdater.shared.canCheckForUpdates)
            Divider()
            Button("Open Bloom", systemImage: "macwindow") {
                model.dismiss()
                MainWindow.raise()
            }
            Button("Bloom Settings\u{2026}", systemImage: "gear") {
                model.dismiss()
                MenuBarStatusItem.openBloomSettings()
            }
            Divider()
            Button("Quit Bloom", systemImage: "power", role: .destructive) {
                NSApp.terminate(nil)
            }
        } label: {
            HStack(spacing: 5) {
                Text("Options")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
