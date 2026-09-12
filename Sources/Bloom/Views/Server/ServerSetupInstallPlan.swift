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
                Text(alreadyInstalled ? "Projects run as the bloom account. Starts automatically." : "Creates a bloom account for projects. Starts automatically.")
                    .font(Typo.caption).foregroundStyle(.secondary)
                ServerSetupHelpButton(title: "Account and startup", details: "Bloom adds this Mac’s public SSH key to the dedicated server account. The private key stays on your Mac. Startup uses systemd. Existing projects, conversations and sign-ins are preserved.")
            }
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                HStack(spacing: Metrics.spacing) {
                    Text("Account files").font(Typo.captionEmphasis)
                    ServerSetupHelpButton(title: "Files and system changes", details: locations)
                }
                Text((serviceHome ?? "/home/bloom") + "/bloom")
                    .font(Typo.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
                Text("A root-owned maintenance service manages updates and recovery.")
                    .font(Typo.caption).foregroundStyle(.secondary)
                ServerSetupHelpButton(title: "Maintenance service", details: maintenanceLocations)
            }
        }
    }

    private var maintenanceLocations: String {
        "The maintenance supervisor runs as root. Bloom Server and project processes run as the bloom account."
            + "\n\nSupervisor and support modules: /usr/local/libexec"
            + "\nProtected settings, update history and recovery data: /var/lib/bloom-maintenance/bloom-server"
            + "\nVerified server releases: /var/lib/bloom-maintenance/bloom-server/releases"
            + "\nConnection socket: /run/bloom-maintenance"
            + "\n\nProjects and account files remain in " + (serviceHome ?? "/home/bloom") + "/bloom. Sign-ins use the account’s configuration folders."
    }

    private var locations: String {
        "Installed package: " + (installationRoot ?? "/home/bloom/bloom/server")
            + "\nServer data: " + (dataDirectory ?? "/home/bloom/bloom/data")
            + "\nAccount home: " + (serviceHome ?? "/home/bloom")
            + "\n\nOS packages and the startup service use system locations. Optional browser tools use /opt/bloom-browser. Sign-ins use the account’s configuration folders."
            + "\n\nCodex and Claude Code install during sign-in when needed. PHP and databases are configured per project, often using Docker."
    }
}
