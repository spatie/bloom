import SwiftUI

/// The review is the one place for the complete installation decision.
struct ServerSetupInstallPlan: View {
    var installationRoot: String?
    var serviceHome: String?
    var dataDirectory: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            item("Software", detail: "Installs Bloom Server and development tools. Reuses compatible tools already installed.")
            item("Account and startup", detail: "Creates a private bloom account, adds this Mac’s public SSH key and starts Bloom automatically.")
            item("Your projects", detail: "Existing projects, conversations and sign-ins are preserved.")
            DisclosureGroup("Installation details") {
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    Text("Includes Git, GitHub CLI, tmux, Node.js, npm and trusted CA certificates. Startup uses systemd.")
                    LabeledContent("Server files", value: installationRoot ?? "/home/bloom/bloom/server")
                    LabeledContent("Server data", value: dataDirectory ?? "/home/bloom/bloom/data")
                    LabeledContent("Account home", value: serviceHome ?? "/home/bloom")
                    Text("OS packages and the startup service use system locations. Browser tools use /opt/bloom-browser. Sign-ins use the account’s configuration folders.")
                    Text("Codex and Claude install during sign-in. Configure PHP, Docker and databases per project.")
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
