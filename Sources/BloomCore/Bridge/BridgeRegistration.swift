import Foundation

/// Everything the shim needs to reach one session, as a value.
public struct BridgeAttachment: Sendable, Hashable {
    public let shimPath: String
    public let socketPath: String
    public let token: String
    public let role: BridgeRole

    public init(shimPath: String, socketPath: String, token: String, role: BridgeRole) {
        self.shimPath = shimPath
        self.socketPath = socketPath
        self.token = token
        self.role = role
    }

    /// The three variables, and nothing else. The shim inherits the rest of the CLI's environment
    /// and needs none of it.
    public var environment: [String: String] {
        [
            BridgeProtocol.socketVariable: socketPath,
            BridgeProtocol.tokenVariable: token,
            BridgeProtocol.roleVariable: role.rawValue,
        ]
    }
}

/// How each CLI is told the bridge exists. Two completely different mechanisms, both verified
/// against the installed binaries, and one shared name that is doing more work than it looks.
public enum BridgeRegistration {
    /// The MCP server's name, and a **correctness requirement with a test behind it** rather than
    /// a convention.
    ///
    /// Codex `-c` overrides do not shadow a colliding `mcp_servers.<name>` entry, they deep-merge
    /// it leaf by leaf, and this was measured rather than assumed. Against a config holding a
    /// user's own server called `bloom`, overriding `command` and `env` produced Bloom's binary
    /// launched with the USER's `args` and the user's `env` key still present, and
    /// `codex mcp list` reported that chimera as one healthy server with no warning at all. There
    /// is no `-c` form that replaces a whole entry: overriding the entire inline table still
    /// merged `env` key by key. So the only defence against a collision is a name nobody would
    /// ever type, and the failure it prevents does not look like a naming problem when it happens.
    ///
    /// Claude Code has the same exposure for a milder reason: `--mcp-config` is additive over the
    /// user's own servers on purpose (never `--strict-mcp-config`, which would shut theirs out),
    /// so a shared name is a name that can be taken.
    public static let serverName = "bloom-workspace-bridge"

    /// The name the owner's own client registers Bloom under, **derived per copy of the app** and
    /// deliberately not `serverName`.
    ///
    /// Two separate collisions are being avoided and they are not the same one.
    ///
    /// It is not `serverName` because a standalone registration lives in `~/.claude.json` at user
    /// scope, which Claude Code applies to every session on the machine, and Bloom's own
    /// `--mcp-config` is documented above as additive over exactly that file rather than replacing
    /// it. So an agent Bloom launched inside a workspace would meet two entries called the same
    /// thing: its own session token and the owner's standalone one, in one client, in one
    /// `tools/list`. Whichever won, the loser would be a server that silently stopped being what
    /// it said it was, and the winning case is the worse one, because a workspace agent holding
    /// the owner's token would have the owner's tools.
    ///
    /// It is derived rather than a constant because the constant it used to be was
    /// `bloom-owner-bridge` for every copy of the app at once, and `claude mcp add` replaces an
    /// existing entry of the same name **without saying so**. User scope is one file for the whole
    /// machine, so Bloom and Bloom Dev each offered a command claiming that one entry and whichever
    /// was pasted last silently evicted the other, with nothing on screen to say it had happened.
    /// `BridgeSocketPath` and `BridgeOwnerToken` both set out at length why those two copies must
    /// never share per-instance state. The registered name is per-instance state, and it was the
    /// last piece of it still shared.
    ///
    /// The derivation is `Store.databaseDirectoryName`, slugified, and reusing that table is the
    /// point rather than a shortcut: it is already the one rule that decides which copy of Bloom a
    /// process is, so two builds can only collide on a name here if they were already sharing a
    /// database, and copies sharing a database share the token beside it and have nothing to
    /// evict. The owner's copy gets `bloom`, which is also the plain name the pane is asked to
    /// show; the dev copy gets `bloom-dev`; anything else gets a name that says what it is instead
    /// of impersonating one of those two.
    public static var ownerServerName: String {
        ownerServerName(forBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// A pure function of the identifier, for the same reason `Store.databaseDirectoryName` is
    /// one: `Bundle.main` cannot be varied inside a process, and this rule is worth a test.
    public static func ownerServerName(forBundleIdentifier identifier: String?) -> String {
        let slug = slugified(Store.databaseDirectoryName(forBundleIdentifier: identifier))
        // A directory name that slugified to nothing would be handed to `claude mcp add` as an
        // empty argument, which makes it read the shim path as the server name. No identifier
        // reaches that today, since every arm of the table above begins with "Bloom"; this is the
        // answer for the day one does.
        return slug.isEmpty ? "bloom" : slug
    }

    /// Lowercased, every run of anything else collapsed to a single hyphen, the ends trimmed.
    ///
    /// Hyphens survive intact in a server name, measured rather than assumed: the live turn
    /// documented on `claudeArguments` saw `bloom-workspace-bridge` reach the model as
    /// `mcp__bloom-workspace-bridge__whoami`. Nothing else in a directory name is worth finding
    /// out about the hard way, which is why this keeps ASCII letters and digits and drops
    /// everything else, rather than listing the characters seen so far and hoping.
    static func slugified(_ value: String) -> String {
        var slug = ""
        var pendingHyphen = false
        for scalar in value.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                if pendingHyphen, !slug.isEmpty { slug.unicodeScalars.append("-") }
                pendingHyphen = false
                slug.unicodeScalars.append(scalar)
            default:
                pendingHyphen = true
            }
        }
        return slug
    }

    // MARK: The owner's own client

    /// The single line a person copies out of Settings and runs in a terminal.
    ///
    /// One command rather than a paragraph about where JSON goes, because the whole of this
    /// feature's onboarding is getting this arrangement into a config file, and an instruction
    /// that can be pasted is an instruction that cannot be got wrong.
    ///
    /// `--scope user` is the load-bearing flag. Claude Code's three scopes are `local` (this
    /// project, this machine, in `~/.claude.json` under the project's own key), `project` (a
    /// `.mcp.json` file in the working directory, which is meant to be committed and shared with
    /// everyone who clones the repository) and `user` (`~/.claude.json` at the top level, every
    /// project on this machine). The owner's coupling belongs to the owner and to no repository,
    /// so `user` is the only correct one, and it is also the only one that cannot end up in a
    /// commit. See `BridgeToolApproval` and the Settings pane for the other half of that warning.
    ///
    /// Every value is single quoted because a path can hold a space, and Bloom Dev's does.
    public static func ownerAddCommand(_ attachment: BridgeAttachment) -> String {
        let environment = attachment.environment
            .sorted { $0.key < $1.key }
            .map { "-e \(shellQuoted("\($0.key)=\($0.value)"))" }
            .joined(separator: " ")
        return "claude mcp add --scope user \(ownerServerName) \(environment) -- "
            + shellQuoted(attachment.shimPath)
    }

    /// The same owner connection registered in Codex's user configuration.
    public static func ownerCodexAddCommand(_ attachment: BridgeAttachment) -> String {
        let environment = attachment.environment
            .sorted { $0.key < $1.key }
            .map { "--env \(shellQuoted("\($0.key)=\($0.value)"))" }
            .joined(separator: " ")
        return "codex mcp add \(ownerServerName) \(environment) -- "
            + shellQuoted(attachment.shimPath)
    }

    /// A POSIX single quoted word. The one character that cannot appear inside single quotes is a
    /// single quote, which is closed, escaped and reopened in the usual way.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: Claude Code

    /// The file `--mcp-config` is pointed at.
    ///
    /// **A file, not the inline JSON string the same flag also accepts**, because argv is visible
    /// in `ps` and an agent runs `ps` through its own Bash tool as ordinary behaviour. The token
    /// is not a secret, but printing it into a transcript is still a thing to avoid doing for no
    /// reason.
    public static func claudeConfig(_ attachment: BridgeAttachment) throws -> Data {
        let server: [String: Any] = [
            "command": attachment.shimPath,
            "args": [String](),
            "env": attachment.environment,
        ]
        let document: [String: Any] = ["mcpServers": [serverName: server]]
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    /// Writes that file mode 0600 and answers with its path.
    ///
    /// Rewritten from scratch on every process start rather than updated, because the token in it
    /// is minted per launch and a file that survived with a stale one would register a server that
    /// is refused at the handshake.
    public static func writeClaudeConfig(
        _ attachment: BridgeAttachment,
        sessionID: SessionID,
        directory: String
    ) throws -> String {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = (directory as NSString).appendingPathComponent("\(sessionID).mcp.json")
        let data = try claudeConfig(attachment)
        // Written and then chmodded rather than created with attributes, because `createFile`
        // leaves an existing file's mode alone and this path is reused every launch.
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    /// What goes into `AgentRunner.argv`.
    ///
    /// **Never `--strict-mcp-config` alongside it.** That flag exists to shut every other MCP
    /// configuration out, which is exactly right for `WorkspaceNamer` and exactly wrong here: a
    /// chat has to keep the user's own servers. `WorkspaceNamer.swift` passes it deliberately, and
    /// this is the other half of that decision written down.
    ///
    /// Measured on claude 2.1.238 by running one live turn, because there is no free way to ask:
    /// `claude mcp list` rejects `--mcp-config` outright ("error: unknown option"), so the flag is
    /// a top-level session flag and nothing short of a turn exercises it. What that turn showed:
    /// `system/init` listed `mcp_servers` as `uidotsh`, `figma` and `bloom-workspace-bridge`, all
    /// connected, so the file really is additive over the user's own servers; and the tool reached
    /// the model as `mcp__bloom-workspace-bridge__whoami`, with the server name carried through
    /// **including its hyphens**. See `LiveBridgeTests`.
    public static func claudeArguments(configPath: String) -> [String] {
        ["--mcp-config", configPath]
    }

    // MARK: Codex

    /// What goes into `CodexClient.arguments`, after `app-server`.
    ///
    /// `-c` values are parsed as TOML with a fallback to a literal string, and the inline table
    /// form for `env` parses, both verified by running `codex mcp list` against a scratch
    /// `CODEX_HOME`. Bloom already runs one app-server process per chat, so a per-process override
    /// is a per-session registration, the same as Claude Code's per-start argv.
    ///
    /// **Never `--strict-config` alongside it.** It is not the same flag as Claude Code's
    /// `--strict-mcp-config` and it is the same trap: it makes Codex refuse to start on a user
    /// config containing anything this build does not recognise.
    public static func codexArguments(_ attachment: BridgeAttachment) -> [String] {
        let environment = attachment.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(tomlString($0.value))" }
            .joined(separator: ",")
        return [
            "-c", "mcp_servers.\(serverName).command=\(tomlString(attachment.shimPath))",
            "-c", "mcp_servers.\(serverName).args=[]",
            "-c", "mcp_servers.\(serverName).env={\(environment)}",
        ]
    }

    /// A TOML basic string. Every value here is a path or a hex token today, so nothing needs
    /// escaping today; it is escaped anyway because the day a value comes from somewhere else is
    /// the day an unescaped quote closes the string early and the rest of it is parsed as TOML.
    static func tomlString(_ value: String) -> String {
        var escaped = ""
        for character in value.unicodeScalars {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    // MARK: Where the shim is

    /// The shim beside the running executable, which is where `Tools/build.sh` puts it.
    ///
    /// The environment override is read first and exists for the test suite:
    /// `Tools/test-core.sh` mirrors only BloomCore into a package with no executable targets, so
    /// nothing the suite builds contains a shim and the live test has to be handed one that was
    /// built from the real package.
    public static func shimPath(
        beside executable: String? = Bundle.main.executableURL?.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = environment["BLOOM_BRIDGE_SHIM"], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        guard let executable else { return nil }
        let candidate = (executable as NSString).deletingLastPathComponent + "/bloom-bridge"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }
}
