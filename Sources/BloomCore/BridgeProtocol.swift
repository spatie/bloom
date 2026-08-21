import Foundation

/// The contract between `bloom-bridge`, the stdio shim Bloom ships inside its own bundle, and the
/// running app it forwards to over a unix domain socket.
///
/// The shim exists because neither CLI can speak MCP over a unix socket. Claude Code registers an
/// MCP server as a stdio command or an HTTP URL, Codex as a stdio `command` or a streamable HTTP
/// `--url`, and that is the whole list on both. HTTP on localhost was refused for a different
/// reason: one port for the whole machine, reachable by every local process, and impossible to
/// share between Bloom and Bloom Dev, which are a documented permanent pair. So the registered
/// transport is stdio, and the socket sits behind it.
///
/// The shim is a line relay and deliberately not an MCP implementation. Every behaviour that
/// lives in the shim is a behaviour that can skew against the app, because Sparkle replaces the
/// bundle underneath a running Bloom and the CLI launches whatever binary is at the path its
/// config names. A relay changes almost never; the tool surface changes every phase. `initialize`,
/// `tools/list` and `tools/call` are all answered in the app, where they can reach the store.
public enum BridgeProtocol {
    /// The version of the socket conversation, compared for **equality** and never as a range.
    ///
    /// The skew to design for is a NEW shim meeting an OLDER running Bloom: Sparkle swaps the
    /// bundle mid-session, the CLI is relaunched, and the config file written this morning names a
    /// binary that has since been replaced. The mirror case is an old shim meeting a new app. Both
    /// have to fail with a sentence rather than hang, because a hanging tool call is a hung turn
    /// and the model has no way to tell one from the other.
    ///
    /// Bump this whenever the frames below or the MCP dispatch behind them change shape.
    public static let version = 1

    /// Where the shim is told to connect. Derived by the app alone: see `BridgeSocketPath`, which
    /// is the one implementation of the derivation.
    public static let socketVariable = "BLOOM_BRIDGE_SOCKET"

    /// The per-launch token that says which session is calling.
    ///
    /// **Not a secret, and it must not be commented as one.** Any process running as the user can
    /// read `ps`, the mode 0600 config file and the socket itself, and an agent has the user's
    /// whole home directory anyway. What the token buys is that no tool takes a workspace id as a
    /// parameter, so there is nothing for a model to forge, mistype or hold on to after it has
    /// gone stale. What actually holds, whoever connects, is server side: parentage read from the
    /// database, git's own safety reports, and counts.
    public static let tokenVariable = "BLOOM_BRIDGE_TOKEN"

    /// Which tool list the caller expects to see, carried for diagnostics only.
    ///
    /// The server resolves the real role from the database against the token it minted and
    /// ignores this, because anything running as the user can launch the shim by hand with any
    /// role it likes. A claim that disagrees with the database is worth a log line and nothing
    /// more.
    public static let roleVariable = "BLOOM_BRIDGE_ROLE"

    /// What is wrong with this hello, or nil when nothing is.
    ///
    /// Only the version is judged here. The token is the registry's question, and it is asked
    /// second so a version skew is reported as a version skew rather than as an unknown token,
    /// which is what a mismatched shim would otherwise look like.
    public static func problem(with hello: BridgeHello) -> String? {
        guard hello.version != version else { return nil }
        return """
            This copy of Bloom speaks bridge protocol \(version) and bloom-bridge \
            \(hello.shimDescription) speaks \(hello.version). Quit and reopen Bloom.
            """
    }
}

/// The first line the shim sends, before any MCP byte crosses the socket.
public struct BridgeHello: Codable, Sendable, Hashable {
    public var version: Int
    public var token: String
    /// What the shim's environment claimed. Recorded, never trusted. See `BridgeProtocol.roleVariable`.
    public var role: String
    /// Which build the shim came out of, so a mismatch names both halves rather than one.
    public var shim: String?

    public init(version: Int = BridgeProtocol.version, token: String, role: String, shim: String? = nil) {
        self.version = version
        self.token = token
        self.role = role
        self.shim = shim
    }

    var shimDescription: String {
        guard let shim, !shim.isEmpty else { return "at an unnamed build" }
        return "(\(shim))"
    }
}

/// The one line the app sends back. A refusal carries the sentence the shim prints to stderr
/// before it exits, which is the only place a person ever sees it: the CLI reports the server as
/// failed and shows what it wrote.
public struct BridgeWelcome: Codable, Sendable, Hashable {
    public var version: Int
    public var accepted: Bool
    public var problem: String?

    public init(version: Int = BridgeProtocol.version, accepted: Bool, problem: String? = nil) {
        self.version = version
        self.accepted = accepted
        self.problem = problem
    }

    public static func accepting() -> BridgeWelcome {
        BridgeWelcome(accepted: true)
    }

    public static func refusing(_ problem: String) -> BridgeWelcome {
        BridgeWelcome(accepted: false, problem: problem)
    }
}
