import SwiftUI

/// The review is the one place for the complete installation decision.
struct ServerSetupInstallPlan: View {
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            item("Software", detail: "Bloom Server, Git, GitHub CLI, tmux, Node.js, npm and trusted CA certificates. Compatible installed tools are reused.")
            item("Private account and startup", detail: "Creates a dedicated bloom account, adds this Mac’s SSH public key and starts Bloom automatically with systemd.")
            item("Your projects", detail: "Projects and conversations stay on your server. Existing Bloom workspaces are preserved.")
            if !compact {
                DisclosureGroup("Installation locations and project tools") {
                    Text("Server: /opt/bloom-server. Data: /var/lib/bloom. Setup uses administrator access to install missing packages and dependencies.")
                    Text("Codex and Claude install during their sign-in steps. PHP, Docker and databases are configured per project, separately from this setup.")
                }
                .font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func item(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(title).font(Typo.labelEmphasis)
            Text(detail).font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
