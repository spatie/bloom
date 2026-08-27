import Foundation

// MARK: - What is looked for

/// One thing the probe looks for on a server.
///
/// Six, and they are not equal, in the same way and for the same reason that `SetupTool`'s four
/// are not. `git` is the flat requirement, because a workspace is a worktree wherever it lives.
/// `python3` is the second one, and it is new here: `bloomd` is a Python file, so a server with no
/// Python is a server Bloom can talk to and cannot install anything on. Claude Code and Codex are
/// the same pair as on this Mac, where either is enough. `gh` and `tmux` are wanted and not
/// needed.
public enum ServerTool: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case git
    case python3
    case claude
    case codex
    case gh
    case tmux

    public var id: String { rawValue }

    /// The name on PATH, which is also the raw value, spelled out so a rename of a case cannot
    /// silently change what the probe looks for.
    public var executableName: String { rawValue }

    /// The flag that makes it print its version.
    ///
    /// **`tmux` is not `--version` and this was found by asking a real server rather than by
    /// reasoning.** `tmux --version` exits 1 with "tmux: unknown option -- -", so an installed
    /// tmux 3.6 was reported as installed and broken, which is the exact failure the three-state
    /// `ServerToolState` exists to describe and in this case would have been describing Bloom's
    /// own mistake. A per-tool flag rather than one for all of them, so the next tool that spells
    /// it its own way is one line here instead of a wrong row on a pane.
    public var versionFlag: String {
        switch self {
        case .tmux: "-V"
        case .git, .python3, .claude, .codex, .gh: "--version"
        }
    }

    public var title: String {
        switch self {
        case .git: "Git"
        case .python3: "Python 3"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gh: "GitHub CLI"
        case .tmux: "tmux"
        }
    }

    /// The row this becomes in a `SetupReport`, when there is one.
    ///
    /// The welcome window already draws four of these and already knows that a missing Codex is a
    /// note and a missing git is a problem. Mapping onto it rather than inventing a second verdict
    /// means the two screens cannot start disagreeing about what "ready" means. `python3` and
    /// `tmux` have no row there because this Mac does not need either, so they are drawn beside
    /// the report rather than inside it.
    public var setupTool: SetupTool? {
        switch self {
        case .git: .git
        case .claude: .claudeCode
        case .codex: .codex
        case .gh: .gitHub
        case .python3, .tmux: nil
        }
    }

    /// The order the pane lists them in: the two flat requirements, then the agents, then the two
    /// that are optional.
    public static let displayOrder: [ServerTool] = [.git, .python3, .claude, .codex, .gh, .tmux]
}

/// How one tool turned out on one server.
///
/// Three states and not a boolean, for the reason `SetupOutcome` gives: "there and broken" is the
/// state a boolean rounds to "missing", and the two have different fixes. A `codex` that a glibc
/// mismatch stops from starting is installed, is on PATH, and does not work, and telling somebody
/// to install it again is telling them to do the thing they already did.
public enum ServerToolState: Sendable, Hashable {
    case missing
    case present(path: String, version: String?)
    case broken(path: String, detail: String)

    public var isPresent: Bool {
        if case .present = self { return true }
        return false
    }

    /// There, and it did not run. The state a boolean would round to "installed" and the one that
    /// looks like success from a distance.
    public var isBroken: Bool {
        if case .broken = self { return true }
        return false
    }

    public var path: String? {
        switch self {
        case .present(let path, _), .broken(let path, _): path
        case .missing: nil
        }
    }

    public var version: String? {
        if case .present(_, let version) = self { return version }
        return nil
    }
}

/// One tool, what happened, and one fact about how it was found.
public struct ServerToolFinding: Sendable, Hashable, Identifiable {
    public var tool: ServerTool
    public var state: ServerToolState
    /// True when the tool exists but a plain `ssh server claude` would not find it.
    ///
    /// **This is the day-one problem, and it is worth a field of its own.** A command run over SSH
    /// with no tty gets a non-interactive, login-less shell, which on most distributions means
    /// `/usr/bin` and little else. An `npm install -g` under `nvm` puts `claude` in
    /// `~/.nvm/versions/node/v22.11.0/bin`, which is on PATH only because `~/.bashrc` put it
    /// there, and `~/.bashrc` returns immediately when there is no tty. So the tool is installed,
    /// the user can see it in their own terminal, and Bloom cannot. The probe widens PATH itself
    /// so the answer is right; this flag is what lets the screen say WHY the answer needed help,
    /// because the same gap will bite anything else that shells out to that name.
    public var needsPathHelp: Bool

    public var id: String { tool.rawValue }

    public init(tool: ServerTool, state: ServerToolState, needsPathHelp: Bool = false) {
        self.tool = tool
        self.state = state
        self.needsPathHelp = needsPathHelp
    }
}

// MARK: - What came back

/// Everything one round trip found out about a server.
public struct ServerFacts: Sendable, Hashable {
    /// The probe script's own format version, so a Bloom that has moved on can say so rather than
    /// mis-reading fields it does not recognise.
    public var formatVersion: Int
    /// `uname -m`. Worth having because an agent CLI shipped as a native binary is built per
    /// architecture, and `aarch64` and `arm64` are the same machine spelled two ways.
    public var architecture: String
    /// `uname -s`: Linux, Darwin, FreeBSD.
    public var system: String
    /// What the server calls itself, out of `/etc/os-release` where there is one. Servers that
    /// have no such file (a Mac, a BSD) say what `uname` says instead, which is why this is a
    /// free string and not an enum.
    public var osName: String
    public var home: String
    /// PATH exactly as the SSH command received it, before the probe widened it. See
    /// `ServerToolFinding.needsPathHelp`.
    public var loginPath: String
    /// PATH the probe actually searched.
    public var searchPath: String
    public var findings: [ServerToolFinding]
    public var diskMount: String
    public var diskAvailableBytes: Int64
    public var diskTotalBytes: Int64
    /// What `bloomd` on the server reports, or nil when there is none there yet.
    public var bloomdVersion: String?

    public init(
        formatVersion: Int,
        architecture: String = "",
        system: String = "",
        osName: String = "",
        home: String = "",
        loginPath: String = "",
        searchPath: String = "",
        findings: [ServerToolFinding] = [],
        diskMount: String = "",
        diskAvailableBytes: Int64 = 0,
        diskTotalBytes: Int64 = 0,
        bloomdVersion: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.architecture = architecture
        self.system = system
        self.osName = osName
        self.home = home
        self.loginPath = loginPath
        self.searchPath = searchPath
        self.findings = findings
        self.diskMount = diskMount
        self.diskAvailableBytes = diskAvailableBytes
        self.diskTotalBytes = diskTotalBytes
        self.bloomdVersion = bloomdVersion
    }

    public func finding(for tool: ServerTool) -> ServerToolFinding? {
        findings.first { $0.tool == tool }
    }

    public func state(of tool: ServerTool) -> ServerToolState {
        finding(for: tool)?.state ?? .missing
    }

    /// The four rows the welcome window already draws, resolved out of the six looked for here.
    ///
    /// A tool that is present but broken becomes `needsSignIn` rather than `ready`, which is not
    /// the word for it and is the honest severity: something is in the way and it is not an
    /// install. The detail carries the actual message, which is what anybody would read anyway.
    public var setupReport: SetupReport {
        SetupReport(checks: SetupTool.displayOrder.map { tool in
            guard let mine = ServerTool.allCases.first(where: { $0.setupTool == tool }) else {
                return SetupCheck(tool: tool, outcome: .missing)
            }
            let outcome: SetupOutcome = switch state(of: mine) {
            case .missing: .missing
            case .present(_, let version): .ready(detail: version)
            case .broken(_, let detail): .needsSignIn(detail: detail)
            }
            return SetupCheck(tool: tool, outcome: outcome)
        })
    }

    /// Whether this server can hold a worktree and be installed on. `bloomd` is Python, so a
    /// server with no Python is one Bloom can look at and cannot use.
    public var canHostWorkspaces: Bool {
        state(of: .git).isPresent && state(of: .python3).isPresent
    }

    /// "412 GB free of 1.02 TB", or just the free half when the total did not come back.
    public var diskSummary: String {
        let free = ByteCountFormatter.string(fromByteCount: diskAvailableBytes, countStyle: .file)
        guard diskTotalBytes > 0 else { return "\(free) free" }
        let total = ByteCountFormatter.string(fromByteCount: diskTotalBytes, countStyle: .file)
        return "\(free) free of \(total)"
    }
}
