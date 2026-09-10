import SwiftUI
import BloomCore

/// Keep the cause and recovery together, where users can correct the connection and retry.
struct ServerSetupNoticeView: View {
    let notice: ServerInstallNotice
    let serviceUser: String
    let showAdvanced: () -> Void
    var stopServer: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                Text(notice.message).foregroundStyle(Palette.warning)
                ServerSetupHelpButton(title: "How to resolve this", details: recoveryDetails)
            }
            HStack(spacing: Metrics.gutter) {
                if let stopServer { Button("Stop Server…", action: stopServer) }
                if notice.code == "service_account_exists" || notice.code == "server_running" || notice.code == "server_busy" {
                    Button("Connect to Existing Server…", action: showAdvanced)
                        .buttonStyle(.link)
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recoveryDetails: String {
        guard notice.code == "service_account_exists" else { return notice.recoverySuggestion }
        return notice.recoverySuggestion + "\n\nInspect the account with these read-only commands in an SSH terminal. Share the results with your administrator before changing or removing the account.\n\ngetent passwd \(ServerSetupSSH.shellQuote(serviceUser))\nps -u \(ServerSetupSSH.shellQuote(serviceUser)) -o pid,comm"
    }
}
