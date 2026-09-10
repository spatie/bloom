import SwiftUI
import BloomCore

/// Keep the cause and recovery together, where users can correct the connection and retry.
struct ServerSetupNoticeView: View {
    let notice: ServerInstallNotice
    let serviceUser: String
    let showAdvanced: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Label(notice.message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Palette.warning)
            Text(notice.recoverySuggestion)
                .font(Typo.caption).foregroundStyle(.secondary)
            if notice.code == "service_account_exists" || notice.code == "server_running" || notice.code == "server_busy" {
                Button("Connect to Existing Server…", action: showAdvanced)
                    .buttonStyle(.link)
            }
            if notice.code == "service_account_exists" {
                DisclosureGroup("Inspect the account") {
                    Text("Run these read-only commands in an SSH terminal on the server. They show the account’s home directory and running processes. Share the results with your administrator before changing or removing the account.")
                        .font(Typo.caption).foregroundStyle(.secondary)
                    Text("getent passwd \(ServerSetupSSH.shellQuote(serviceUser))\nps -u \(ServerSetupSSH.shellQuote(serviceUser)) -o pid,comm")
                        .font(Typo.codeSmall)
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}
