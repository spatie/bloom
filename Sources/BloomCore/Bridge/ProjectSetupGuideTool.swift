import Foundation

/// The facts an agent needs before preparing an unrelated repository for Bloom. A tool rather
/// than a file in Bloom's own checkout, because the worktree being configured cannot read that
/// checkout and the configured SMTP port belongs to this running copy of Bloom.
public struct ProjectSetupGuideTool: BridgeToolHandling {
    public struct MailSettings: Sendable {
        public let isEnabled: Bool
        public let smtpPort: Int

        public init(isEnabled: Bool, smtpPort: Int) {
            self.isEnabled = isEnabled
            self.smtpPort = smtpPort
        }
    }

    private let mailSettings: @Sendable () -> MailSettings

    public init(mailSettings: @escaping @Sendable () -> MailSettings = {
        let defaults = UserDefaults.standard
        let port = defaults.object(forKey: MailpitSettings.smtpPortKey) as? Int
            ?? MailpitSettings.bundledPorts(forBundleIdentifier: Bundle.main.bundleIdentifier).smtp
        let enabled = MailpitSettings.isEnabled(in: defaults)
        return MailSettings(isEnabled: enabled, smtpPort: port)
    }) {
        self.mailSettings = mailSettings
    }

    public let roles: Set<BridgeRole> = [.workspace, .owner]

    public let tool = BridgeTool(
        name: "project_setup_guide",
        description: """
            Read this before setting up an existing repository for use in Bloom. It explains the \
            supported .bloom/settings.toml files and keys, worktree setup and run scripts, and \
            how to configure the project's mail transport for this copy of Bloom's Incoming mails \
            inbox. It reports the currently configured SMTP port. Read only: it does not inspect \
            or change the repository. Inspect the project's framework and existing configuration \
            before choosing commands or editing files.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        BridgeToolResult(text: Self.guide(mail: mailSettings()))
    }

    public static func guide(mail: MailSettings) -> String {
        let inboxState = mail.isEnabled
            ? "Incoming mails is enabled in this copy of Bloom."
            : "Incoming mails is off in this copy of Bloom. Enable it in Settings > Incoming mails before testing delivery."
        return """
        To prepare an existing repository for Bloom:

        1. Inspect the repository's existing framework, package scripts, environment files and \
        any .bloom or .conductor settings. Register it with project_add only if it is already a \
        Git repository and the owner asked you to add it. Do not run git init just for Bloom.
        2. Put shared worktree settings in <repo>/.bloom/settings.toml. Put machine-specific values \
        in <repo>/.bloom/settings.local.toml, and ensure that local file is Git-ignored if editing \
        it by hand. Only write sections the project actually needs. A supported example is:

           [scripts]
           setup_file = ".bloom/setup.sh"

           [scripts.run.dev]
           command = "the project's development command"

           [browser]
           url = "http://localhost:$BLOOM_PORT"

           Replace the example command with one verified in this repository; do not commit the \
        placeholder. Script paths are relative to the repository root. The setup script runs in each new \
        worktree after creation. Named run scripts are shown in Bloom's Run menu. Bloom supplies \
        BLOOM_PORT to scripts and expands it in browser.url. The project settings window can \
        edit these values. By default Bloom copies .env* into new worktrees; change that with the \
        top-level file_include_globs list only when needed. Do not invent a mail table in settings.toml.
        3. Mail capture is app-wide, not a repository setting. \(inboxState) Configure this \
        project's existing mail transport to use SMTP host 127.0.0.1, port \(mail.smtpPort), no \
        encryption and no authentication. Keep framework-specific credentials and .env files out \
        of shared settings. If the port changes in Bloom Settings, update the project's mail \
        configuration too.
        4. Verify the project's wiring by sending mail through the project's own command or app \
        and checking Bloom's Incoming mails with mail_list and mail_read. The mail_send bridge \
        tool can check Bloom's inbox, but it bypasses the project's mail configuration.
        """
    }
}
