import SwiftUI
import BloomCore

/// The strip along the bottom of the panel: whether an ask is out, and the Options menu.
struct UsagePanelFooter: View {
    let app: AppModel
    @Environment(UsagePanelModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // No version and no countdown to the next ask. Both were noise on a panel opened to
            // read one number, and the countdown invited somebody to wait for it; asking takes a
            // second and happens every minute anyway. What is left is the one thing worth saying
            // while it happens, which is that it is happening.
            if app.isAskingForQuotas {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Updating")
            }
            Spacer(minLength: 0)
            if model.screen == .dashboard {
                UsageOptionsMenu(app: app)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: Rectangle())
    }
}

/// Everything the panel does that is not a row: its two other screens, screenshots, updates, the
/// main window, and quitting.
struct UsageOptionsMenu: View {
    let app: AppModel
    @Environment(UsagePanelModel.self) private var model

    var body: some View {
        Menu {
            Button("Refresh Now", systemImage: "arrow.clockwise") { model.refresh() }
                .disabled(app.isAskingForQuotas)
            Divider()
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
