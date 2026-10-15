import SwiftUI
import BloomCore

/// Settings > Incoming mails: an app-owned inbox and the SMTP port apps send to.
struct MailSettingsView: View {
    private var preferences = MailpitPreferences()

    private var mailbox: Mailbox { .shared }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: preferences.$isEnabled) {
                    Text("Enable incoming mails")
                    Text("Bloom receives test emails while it is open. No separate installation is needed.")
                }
            } header: {
                Text("Incoming mails")
            } footer: {
                Text(status).settingsFootnote()
            }

            Section {
                SettingsRow("SMTP host") {
                    Text("127.0.0.1").font(Typo.codeSmall).textSelection(.enabled)
                }
                SettingsRow("SMTP port") {
                    TextField("SMTP port", value: preferences.$smtpPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 96)
                }
                SettingsRow("Encryption") { Text("None") }
                SettingsRow("Authentication") { Text("None") }
                MailSetupButton(port: preferences.smtpPort)
            } header: {
                Text("Send test mail from your app")
            }
        }
        .settingsForm()
    }

    private var status: String {
        mailbox.statusLine(isEnabled: preferences.isEnabled, port: preferences.smtpPort)
    }
}
