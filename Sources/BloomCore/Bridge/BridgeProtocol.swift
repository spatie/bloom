import Foundation

/// The contract between `bloom-bridge`, the stdio shim Bloom ships inside its own bundle, and the
/// running app it forwards to over a unix domain socket.
///
/// The shim exists because neither CLI can speak MCP over a unix socket. Claude Code registers an
/// MCP server as a stdio command or an HTTP URL, Codex as a stdio `command` or a streamable HTTP
/// `--url`, and that is the whole list on both. HTTP on localhost was refused for a different
/// reason: one port for the whole machine, reachable by every local process, and impossible to
/// share between Bloom and the copies installed beside it, which are a documented permanent
/// arrangement rather than a test setup. So the registered transport is stdio, and the socket sits
/// behind it.
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

    /// Why a token the registry has never heard of got nowhere, said to whoever presented it.
    ///
    /// Two kinds of token reach this handshake and they die of completely different things, so one
    /// sentence cannot serve both. A session token is minted for a process Bloom is about to
    /// launch and is held in memory only, so a quit really does retire it and reopening Bloom
    /// really does mint another; telling that caller to restart is telling it the truth. The
    /// owner's standalone token is the opposite by design, and `BridgeOwnerToken` sets out at
    /// length why: it is handed over once, it is meant to outlive every relaunch, and it ends when
    /// the owner regenerates it. Sending that caller away to quit and reopen Bloom is sending it
    /// to do the one thing that cannot change the answer, after which it presents the same dead
    /// token and is refused again in the same words.
    ///
    /// The claimed role is what tells them apart. It comes out of the shim's environment, so it is
    /// worth nothing as authority, which is why an accepted connection reads the role off the
    /// database instead and logs the claim when the two disagree. Here there is no row to read:
    /// the token matched nothing, so the claim is the only evidence there is, and this is the
    /// diagnostic use it is carried for. A caller that lies about it reads a sentence about a
    /// registration it does not have, which costs nobody anything.
    ///
    /// Neither sentence quotes the registration command or the path it names. What a person needs
    /// is the pane the command is offered in, which they can reach; what a model needs is to know
    /// that this is the owner's to fix and not its own to retry.
    public static func unrecognisedToken(claiming role: String) -> String {
        guard role == BridgeRole.owner.rawValue else {
            // Minted per launch, held in memory, retired by a quit. The ordinary cause is a config
            // file left over from a launch that has since ended.
            return "Bloom does not recognise this token. It was minted by a previous launch; "
                + "quit and reopen Bloom."
        }
        return """
            Bloom does not recognise this token. It came from a standalone registration, and that \
            kind of token is meant to outlive a quit, so restarting Bloom will not bring it back \
            and no retry with this token will connect. Either the token was regenerated in Bloom's \
            Settings, which revokes the one it replaced, or this entry belongs to a different copy \
            of Bloom: each copy registers under its own name and keeps its own token beside its \
            own database, so an entry written against a copy that has since been removed, replaced \
            or pointed at other data outlives the token that made it work. Both are put right the \
            same way: open Bloom's Settings and run the registration command it offers there again.
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
