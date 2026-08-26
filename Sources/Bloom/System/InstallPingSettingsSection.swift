import SwiftUI
import BloomCore

/// The "may Bloom count this install" row, as a section the General pane can drop in.
///
/// A section of its own for the same reason `SleepSettingsSection` and `UpdateSettingsSection`
/// are: it is a switch that cannot be understood from its title alone. A person reading a row
/// about sending anything anywhere wants the list of what is sent, in the row, not in a privacy
/// page they would have to go and find. So the five fields are named underneath the switch and the
/// footer answers the question behind the question, which is whether any of their work is in it.
///
/// The default lives on `InstallPing.isOnByDefault` and is registered in `SystemDefaults`. An
/// `@AppStorage` literal here that disagreed with the registered default is exactly how the menu
/// bar switch once drew off while the item it controls was in the menu bar.
struct InstallPingSettingsSection: View {
    @AppStorage(InstallPing.settingKey) private var sendsInstallPing = InstallPing.isOnByDefault

    var body: some View {
        Section {
            // A switch with its explanation underneath, matching every other boolean in this
            // window.
            Toggle(isOn: $sendsInstallPing) {
                Text(InstallPing.settingTitle)
                Text(InstallPing.settingDetail)
            }
        } footer: {
            Text(InstallPing.settingFooter)
                .settingsFootnote()
        }
    }
}
