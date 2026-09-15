import SwiftUI
import BloomCore

/// The switch for the whole remote server feature. What it hides and stops, and what it keeps, is
/// `RemoteServerFeature`; `RemoteServerAvailability` is what every other surface reads it through.
struct RemoteServersSettingsSection: View {
    @AppStorage(RemoteServerFeature.settingKey) private var isEnabled = RemoteServerFeature.isOnByDefault

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Text(RemoteServerFeature.settingTitle)
                Text(RemoteServerFeature.settingDetail)
            }
        } header: {
            Text("Servers")
        } footer: {
            Text(RemoteServerFeature.settingFootnote)
                .settingsFootnote()
        }
    }
}
