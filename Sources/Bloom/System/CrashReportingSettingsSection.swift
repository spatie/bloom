import SwiftUI
import BloomCore

struct CrashReportingSettingsSection: View {
    @AppStorage(CrashReporting.settingKey) private var sendsCrashReports = CrashReporting.isOnByDefault

    var body: some View {
        Section {
            Toggle(isOn: $sendsCrashReports) {
                Text("Send crash reports")
                Text("Help us fix crashes by sending technical details when Bloom next opens.")
            }
        } header: {
            Text("Crash reporting")
        } footer: {
            Text("Includes Bloom and macOS versions and crash stack traces. Changes take effect after restarting Bloom.")
                .settingsFootnote()
        }
    }
}
