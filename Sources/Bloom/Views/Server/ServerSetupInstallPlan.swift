import SwiftUI

/// Review names the required software and its destination before optional tools are chosen.
struct ServerSetupInstallPlan: View {
    var installationRoot: String?
    var serviceHome: String?
    var dataDirectory: String?
    var alreadyInstalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(alreadyInstalled ? "Your installation" : "Included with Bloom Server").font(Typo.labelEmphasis)
                Text("Git, GitHub CLI, tmux, Node.js, npm and trusted CA certificates. Compatible tools already installed are reused.")
                    .font(Typo.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
                Text(alreadyInstalled ? "Runs as the bloom account and starts automatically." : "Creates a bloom account and starts automatically.")
                    .font(Typo.caption).foregroundStyle(.secondary)
                ServerSetupHelpButton(title: "Account and startup", details: "Bloom adds this Mac’s public SSH key to the dedicated server account. The private key stays on your Mac. Startup uses systemd. Existing projects, conversations and sign-ins are preserved.")
            }
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                HStack(spacing: Metrics.spacing) {
                    Text("Install location").font(Typo.captionEmphasis)
                    ServerSetupHelpButton(title: "Files and system changes", details: locations)
                }
                Text(installationRoot ?? "/home/bloom/bloom/server")
                    .font(Typo.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var locations: String {
        "Server files: " + (installationRoot ?? "/home/bloom/bloom/server")
            + "\nServer data: " + (dataDirectory ?? "/home/bloom/bloom/data")
            + "\nAccount home: " + (serviceHome ?? "/home/bloom")
            + "\n\nOS packages and the startup service use system locations. Optional browser tools use /opt/bloom-browser. Sign-ins use the account’s configuration folders."
            + "\n\nCodex and Claude Code install during sign-in when needed. PHP and databases are configured per project, often using Docker."
    }
}
