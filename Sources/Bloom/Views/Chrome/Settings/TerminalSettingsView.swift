import AppKit
import SwiftUI
import BloomCore

/// Terminal lifecycle settings. Appearance belongs to the selected theme.
struct TerminalSettingsView: View {
    @AppStorage(TerminalPersistence.defaultsKey) private var persistsTerminals = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep terminals running after quitting", isOn: $persistsTerminals)
                    .disabled(!TerminalPersistence.isTmuxInstalled)
                    .help(
                        "Terminals run in tmux instead of inside Bloom, so they survive a quit "
                        + "and come back on the next launch."
                    )
            } header: {
                Text("After quitting Bloom")
            } footer: {
                Text(TerminalSettingsCopy.persistence(isTmuxInstalled: TerminalPersistence.isTmuxInstalled))
                    .settingsFootnote()
            }
        }
        .settingsForm()
    }

}
