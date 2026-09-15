import Foundation

/// What uninstalling will remove and what it will keep, worded for the confirmation.
///
/// The installer decides for itself on the server and reports the result, so this is a promise
/// about the managed layout rather than an inventory. It lives here because the two choices that
/// matter most (keep the account's data, or delete it) change the list, and a list that quietly
/// omitted the account's data from one branch would be the kind of mistake nobody forgives.
public struct ServerUninstallPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public let title: String
        public let detail: String
        public var id: String { title }
    }

    public var serviceUser: String
    public var serviceHome: String
    public var installationRoot: String
    public var deletesData: Bool

    public init(serviceUser: String, serviceHome: String?, installationRoot: String?, deletesData: Bool) {
        self.serviceUser = serviceUser.isEmpty ? "bloom" : serviceUser
        self.serviceHome = serviceHome ?? "/home/" + self.serviceUser
        self.installationRoot = installationRoot ?? self.serviceHome + "/bloom/server"
        self.deletesData = deletesData
    }

    public init(check: ServerInstallCheck, deletesData: Bool) {
        self.init(serviceUser: check.serviceUser, serviceHome: check.serviceHome,
                  installationRoot: check.installationRoot, deletesData: deletesData)
    }

    public var removed: [Item] {
        var items = [
            Item(title: "Bloom Server",
                 detail: "The program in \(installationRoot) and the service that starts it. Running agents and terminals stop."),
            Item(title: "Maintenance service",
                 detail: "Updates and recovery, with its saved releases in /var/lib/bloom-maintenance and its programs in /usr/local/libexec."),
            Item(title: "Optional tools Bloom added",
                 detail: "Browser testing tools in /opt/bloom-browser, the 2 GB swap file and the raised file watch limit, if they were installed. Docker containers of the \(serviceUser) account stop."),
        ]
        if deletesData {
            items.append(Item(title: "The \(serviceUser) account and all of its data",
                              detail: "Projects, repositories, workspaces, conversations, the server database and GitHub, Claude and Codex sign-ins in \(serviceHome). This can’t be undone."))
        } else {
            items.append(Item(title: "This Mac’s key for the \(serviceUser) account",
                              detail: "This Mac can no longer sign in to the account."))
        }
        return items
    }

    public var kept: [Item] {
        var items: [Item] = []
        if !deletesData {
            items.append(Item(title: "The \(serviceUser) account and its data",
                              detail: "Projects, repositories, conversations and sign-ins stay in \(serviceHome). Installing Bloom Server again picks them up."))
        }
        items.append(Item(title: "Shared software",
                          detail: "Git, GitHub CLI, tmux, Node.js, npm, CA certificates and Docker packages stay, because other software may use them."))
        items.append(Item(title: "This server in Bloom",
                          detail: "It stays in the sidebar until you remove it. Bloom offers to remove it when uninstalling finishes."))
        return items
    }

    public func confirmationTitle(server: String) -> String {
        deletesData ? "Uninstall Bloom Server and delete all data on \(server)?" : "Uninstall Bloom Server from \(server)?"
    }

    public var confirmationMessage: String {
        deletesData
            ? "Bloom Server, its services and the \(serviceUser) account are removed, with every project, repository and conversation on the server. This can’t be undone."
            : "Bloom Server and its services are removed. The \(serviceUser) account keeps your projects, repositories and conversations."
    }

    public var confirmationButton: String { deletesData ? "Uninstall and Delete Data" : "Uninstall" }

    /// Flags only, never values, so nothing typed in the app can reach the remote command line.
    public static func installerArguments(deletesData: Bool, force: Bool) -> [String] {
        ["--uninstall"] + (deletesData ? ["--delete-data"] : []) + (force ? ["--force"] : [])
    }

    /// The installer's check is the gate: an existing installation reached with administrator
    /// rights. Blockers such as a running service are what uninstalling deals with, not reasons to hide it.
    public static func canUninstall(_ check: ServerInstallCheck) -> Bool {
        check.existing && check.privilege != "none"
    }

    /// Refusals the installer lifts with `--force`. Anything else means Bloom could not identify
    /// what it would delete, and no button should make it try.
    public static func canForce(afterFailure code: String) -> Bool {
        ["server_busy", "maintenance_busy", "database_unavailable"].contains(code)
    }

    public static let forceTitle = "Uninstall anyway?"
    public static let forceMessage = "Agents, workspace setup or an update are still running. Uninstalling stops them, and unfinished work in them is lost."
    public static let forceButton = "Uninstall Anyway"
}
