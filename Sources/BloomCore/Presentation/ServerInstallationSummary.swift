import Foundation

/// The plain account of what a Bloom Server installation is: what it needs, what it puts where,
/// what runs in the background and what it cannot do.
///
/// Setup used to name the software in one sentence and hide every path in help popovers, and the
/// supported Ubuntu versions appeared only as an error after the check had failed. The same facts
/// are shown before installing and afterwards in Server Settings, so they are written once, here.
public struct ServerInstallationSummary: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let symbol: String
        public let title: String
        public let detail: String
        public let location: String?
        public var id: String { title }
    }

    public enum OptionalPart: String, CaseIterable, Sendable {
        case docker, browser, swap

        public var title: String {
            switch self {
            // Short enough for one line in a third of the setup page, where the three sit side by side.
            case .docker: "Docker for containers"
            case .browser: "Browser testing tools"
            case .swap: "Add 2 GB of swap"
            }
        }

        /// What it is for, then what it costs, because a toggle that is on by default should say both.
        public var summary: String {
            switch self {
            case .docker: "Runs apps and databases in containers. A few hundred megabytes, plus images."
            case .browser: "Lets agents test websites in a sandboxed Chrome. A few hundred megabytes."
            case .swap: "Keeps the server responsive when memory runs short. Uses 2 GB of disk."
            }
        }

        public func details(serviceUser: String = "bloom", serviceHome: String? = nil) -> String {
            let home = serviceHome ?? "/home/" + serviceUser
            switch self {
            case .docker:
                return "Installs Ubuntu’s Docker and Compose packages. Docker runs as the \(serviceUser) account without administrator rights, and starts again when the server restarts."
                    + "\n\nImages and container data: " + home + "/bloom/docker/data"
                    + "\n\nBloom also raises how many files one account can watch, so development servers can follow large projects. Docker projects can run commands and read files as the \(serviceUser) account."
            case .browser:
                return "Installs agent-browser, Chrome, the libraries Chrome needs and fonts in /opt/bloom-browser. On Ubuntu versions that restrict sandboxes, Bloom adds a security rule that lets only this Chrome use its sandbox."
                    + "\n\nPreviewing websites in Bloom works without these tools. Docker projects need their own browser setup."
            case .swap:
                return "Swap lets the server use disk space when memory is full. Bloom creates /var/lib/bloom/swapfile, which only administrators can change, and turns it on after every restart. Setup needs 4 GB free so at least 2 GB stays available. Existing swap is always kept."
            }
        }
    }

    public var serviceUser: String
    public var serviceHome: String
    public var installationRoot: String
    public var dataDirectory: String

    public init(serviceUser: String? = nil, serviceHome: String? = nil, installationRoot: String? = nil, dataDirectory: String? = nil) {
        let user = serviceUser.flatMap { $0.isEmpty ? nil : $0 } ?? "bloom"
        self.serviceUser = user
        self.serviceHome = serviceHome ?? "/home/" + user
        self.installationRoot = installationRoot ?? self.serviceHome + "/bloom/server"
        self.dataDirectory = dataDirectory ?? self.serviceHome + "/bloom/data"
    }

    /// For a saved connection, which knows the executable and data directory but not the account's
    /// home. The managed layout puts both under the home, so it is recovered from them when it can be.
    public init(connectionHost: String, executable: String, dataDirectory: String) {
        let user = connectionHost.contains("@") ? connectionHost.split(separator: "@").first.map(String.init) : nil
        let executableSuffix = "/current/bin/bloom-server", dataSuffix = "/bloom/data"
        let root = executable.hasSuffix(executableSuffix) ? String(executable.dropLast(executableSuffix.count)) : nil
        let home = dataDirectory.hasSuffix(dataSuffix) ? String(dataDirectory.dropLast(dataSuffix.count)) : nil
        self.init(serviceUser: user, serviceHome: home, installationRoot: root,
                  dataDirectory: dataDirectory.isEmpty ? nil : dataDirectory)
    }

    // MARK: Before setup

    public static let requirementsTitle = "What you need"
    public static let supportedSystem = "An Ubuntu 24.04 or 26.04 server with an x86_64 (Intel or AMD) processor, from any provider."
    public static let administratorAccess = "An SSH login as root, or with sudo that doesn’t ask for a password. It’s used only to install and maintain Bloom Server."
    public static let separateAccount = "Bloom creates a separate bloom account that runs everything afterwards."
    public static let addressHint = "Use root, or an account with sudo that doesn’t ask for a password. Bloom uses it only to install Bloom Server; agents and projects run as a separate bloom account."

    // MARK: What gets installed

    // One short sentence each. The setup page has to show these, the optional extras and the Install
    // button in one window without scrolling, and three line details pushed the extras below the
    // fold. What the details used to add (package sources, keys, where sign-ins live) is in
    // `locationDetails`, one click away.

    public var software: Row {
        Row(symbol: "hammer", title: "Development tools",
            detail: "Git, GitHub CLI, tmux, Node.js and npm. Tools already there are reused.",
            location: nil)
    }

    public var account: Row {
        Row(symbol: "person.crop.circle", title: "A separate \(serviceUser) account",
            detail: "Runs Bloom Server, your agents and projects, without administrator rights.",
            location: serviceHome)
    }

    public var data: Row {
        Row(symbol: "folder", title: "Your projects and data",
            detail: "Repositories, workspaces, conversations and the server database.",
            location: serviceHome + "/bloom")
    }

    public var services: [Row] {
        [
            Row(symbol: "server.rack", title: "Bloom Server",
                detail: "Starts with the server, so agents keep working while this Mac sleeps.",
                location: nil),
            Row(symbol: "wrench.and.screwdriver", title: "Maintenance service",
                detail: "Installs and recovers updates as administrator. It doesn’t run projects.",
                location: "/var/lib/bloom-maintenance"),
        ]
    }

    public var rows: [Row] { [software, account, data] + services }

    /// Every path, for the one reader who wants them all, kept out of the list itself. The rows no
    /// longer carry paths or the finer print, so everything they dropped has to be here.
    public var locationDetails: String {
        "Account home: " + serviceHome
            + "\nProjects and data: " + serviceHome + "/bloom"
            + "\nBloom Server program: " + installationRoot
            + "\nServer database: " + dataDirectory
            + "\nWorkspaces: " + serviceHome + "/bloom/workspaces.noindex"
            + "\n\nMaintenance programs: /usr/local/libexec"
            + "\nMaintenance settings, update history and saved releases: /var/lib/bloom-maintenance/bloom-server"
            + "\n\nStartup service: /etc/systemd/system/bloom-server.service"
            + "\nOptional browser tools: /opt/bloom-browser"
            + "\nOptional swap file: /var/lib/bloom/swapfile"
            + "\n\nDevelopment tools come from Ubuntu’s packages. Codex and Claude Code are installed in the account when you sign in to them, and their sign-ins stay in the account’s own settings folders. PHP and databases are set up per project, often with Docker."
            + "\n\nThis Mac signs in to the \(serviceUser) account with its own key, and that private key never leaves this Mac. Existing projects, conversations and sign-ins are kept."
    }

    // MARK: Limits

    public static let limits: [Row] = [
        Row(symbol: "arrow.left.arrow.right", title: "One server at a time",
            detail: "Bloom connects to one server at a time. Switching servers disconnects this Mac from the current one, and its agents keep running there. Switch from the server’s menu in the sidebar.",
            location: nil),
        Row(symbol: "clock.arrow.circlepath", title: "Changes appear within seconds",
            detail: "Bloom checks the server for new messages and changes every few seconds, so activity from another device can take a moment to show.",
            location: nil),
        Row(symbol: "trash", title: "Removing is separate from uninstalling",
            detail: "Remove Server forgets the connection on this Mac and leaves Bloom Server running. Uninstall Bloom Server removes it from the server.",
            location: nil),
    ]
}
