import SwiftUI

/// The review is the one place for the complete installation decision.
struct ServerSetupInstallPlan: View {
    var installationRoot: String?
    var serviceHome: String?
    var dataDirectory: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            item("Software", detail: "Bloom Server, Git, GitHub CLI, tmux, Node.js, npm and trusted CA certificates. Compatible installed tools are reused.")
            item("Private account and startup", detail: "Creates a dedicated bloom account, adds this Mac’s SSH public key and starts Bloom automatically with systemd.")
            item("Your projects", detail: "Projects and conversations stay on your server. Existing Bloom workspaces are preserved.")
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("Installation locations").font(Typo.labelEmphasis)
                LabeledContent("Server files", value: installationRoot ?? "/home/bloom/bloom/server")
                LabeledContent("Server data", value: dataDirectory ?? "/home/bloom/bloom/data")
                LabeledContent("Account home", value: serviceHome ?? "/home/bloom")
                Text("OS packages and the startup service use system locations. Sandboxed browser tools use /opt/bloom-browser. Tool sign-ins use the account’s standard configuration folders.")
            }
            .font(Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Codex and Claude install during sign-in. PHP, Docker and databases are configured separately for each project.")
                .font(Typo.caption).foregroundStyle(.secondary)

        }
    }

    private func item(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(title).font(Typo.labelEmphasis)
            Text(detail).font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
